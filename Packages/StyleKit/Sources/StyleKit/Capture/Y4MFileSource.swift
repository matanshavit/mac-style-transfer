import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

public enum Y4MError: Error, CustomStringConvertible {
    case invalidHeader(String)
    case unsupportedColorspace(String)
    case noFrames

    public var description: String {
        switch self {
        case .invalidHeader(let detail): "invalid YUV4MPEG2 header: \(detail)"
        case .unsupportedColorspace(let tag): "unsupported y4m colorspace \(tag); only 8-bit 4:2:0 is supported"
        case .noFrames: "y4m file has no complete frames"
        }
    }
}

/// Reads an 8-bit 4:2:0 YUV4MPEG2 file and emits BGRA IOSurface frames, either paced like a camera or as fast as
/// the handler accepts them.
public final class Y4MFileSource: FrameSource, @unchecked Sendable {
    public enum Pacing: Sendable {
        case realtime
        case asFastAsPossible
    }

    public let url: URL
    public let width: Int
    public let height: Int
    public let fileFrameRate: Double
    public let fileFrameCount: Int
    /// File frames advanced per emitted frame, e.g. 2 when a 60 fps file is played at 30 fps.
    public let frameStep: Int
    public let frameDuration: CMTime
    public let pacing: Pacing
    public let maxFrames: Int?
    public let loops: Bool

    public var frameRate: Double { fileFrameRate / Double(frameStep) }

    /// Frames a full run emits, or nil when looping without a frame limit.
    public var outputFrameCount: Int? {
        if loops { return maxFrames }
        return min(framesPerPass, maxFrames ?? framesPerPass)
    }

    private var framesPerPass: Int { (fileFrameCount + frameStep - 1) / frameStep }

    public var skippedFrames: Int { state.withLock { $0.skipped } }
    public var emittedFrames: Int { state.withLock { $0.emitted } }

    private struct RunState {
        var generation = 0
        var running = false
        var next = 0
        var emitted = 0
        var skipped = 0
    }

    private let data: Data
    private let frameOffsets: [Int]
    private let conversion: vImage_YpCbCrToARGB
    private let pool: PixelBufferPool
    private let queue = DispatchQueue(label: "StyleKit.Y4MFileSource", qos: .userInteractive)
    private let state = Mutex(RunState())

    public init(url: URL, frameRate: Double? = nil, pacing: Pacing = .asFastAsPossible, maxFrames: Int? = nil,
                loops: Bool = false) throws {
        self.url = url
        self.pacing = pacing
        self.maxFrames = maxFrames
        self.loops = loops
        data = try Data(contentsOf: url, options: .alwaysMapped)

        guard let headerEnd = data.firstIndex(of: 0x0A) else { throw Y4MError.invalidHeader("no header line") }
        let header = String(decoding: data[data.startIndex..<headerEnd], as: UTF8.self)
        let tokens = header.split(separator: " ")
        guard tokens.first == "YUV4MPEG2" else { throw Y4MError.invalidHeader("missing YUV4MPEG2 signature") }
        var width = 0, height = 0, rateNumerator = 30, rateDenominator = 1
        var colorspace = "420jpeg", fullRange = false
        for token in tokens.dropFirst() {
            let value = token.dropFirst()
            switch token.first {
            case "W": width = Int(value) ?? 0
            case "H": height = Int(value) ?? 0
            case "F":
                let parts = value.split(separator: ":").compactMap { Int($0) }
                if parts.count == 2, parts[0] > 0, parts[1] > 0 { (rateNumerator, rateDenominator) = (parts[0], parts[1]) }
            case "C": colorspace = String(value)
            case "X": if value == "COLORRANGE=FULL" { fullRange = true }
            default: break
            }
        }
        guard width > 0, height > 0 else { throw Y4MError.invalidHeader(header) }
        guard ["420jpeg", "420paldv", "420mpeg2", "420"].contains(colorspace) else {
            throw Y4MError.unsupportedColorspace(colorspace)
        }
        self.width = width
        self.height = height

        let frameBytes = width * height + 2 * ((width + 1) / 2) * ((height + 1) / 2)
        var offsets: [Int] = []
        var cursor = headerEnd + 1
        while cursor < data.endIndex, let lineEnd = data[cursor...].firstIndex(of: 0x0A) {
            let payload = lineEnd + 1
            guard payload + frameBytes <= data.endIndex else { break }
            offsets.append(payload - data.startIndex)
            cursor = payload + frameBytes
        }
        guard !offsets.isEmpty else { throw Y4MError.noFrames }
        frameOffsets = offsets
        fileFrameCount = offsets.count

        fileFrameRate = Double(rateNumerator) / Double(rateDenominator)
        frameStep = max(1, Int((fileFrameRate / (frameRate ?? fileFrameRate)).rounded()))
        frameDuration = CMTime(value: CMTimeValue(frameStep * rateDenominator), timescale: CMTimeScale(rateNumerator))

        var range = fullRange
            ? vImage_YpCbCrPixelRange(Yp_bias: 0, CbCr_bias: 128, YpRangeMax: 255, CbCrRangeMax: 255,
                                      YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
            : vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                      YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var matrix = vImage_YpCbCrToARGBMatrix(Yp: 1, Cr_R: 1.402, Cr_G: -0.714136, Cb_G: -0.344136, Cb_B: 1.772)
        var info = vImage_YpCbCrToARGB()
        let status = vImageConvert_YpCbCrToARGB_GenerateConversion(
            &matrix, &range, &info, kvImage420Yp8_Cb8_Cr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
        guard status == kvImageNoError else { throw Y4MError.invalidHeader("vImage conversion setup failed (\(status))") }
        conversion = info
        pool = try PixelBufferPool(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA, minimumBufferCount: 4)
    }

    public func start(handler: @escaping FrameHandler) throws {
        start(handler: handler, completion: nil)
    }

    /// `completion` runs on the source's queue after the last frame was handed off or after `stop()`.
    public func start(handler: @escaping FrameHandler, completion: (@Sendable () -> Void)?) {
        let generation = state.withLock { state -> Int in
            state = RunState(generation: state.generation + 1, running: true)
            return state.generation
        }
        switch pacing {
        case .asFastAsPossible:
            queue.async { [self] in
                while isCurrent(generation), let index = claimIndex(due: nil) {
                    guard emit(index, hostTime: HostClock.now(), handler: handler) else { break }
                }
                completion?()
            }
        case .realtime:
            // A strict timer: sleeping until a deadline can wake up to 10 ms late under timer coalescing.
            let start = HostClock.now()
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(frameDuration.seconds * 1e9)), leeway: .nanoseconds(0))
            timer.setEventHandler { [self] in
                let due = Int(((HostClock.now() - start).seconds / frameDuration.seconds).rounded(.down))
                guard isCurrent(generation), let index = claimIndex(due: due),
                      emit(index, hostTime: start + CMTimeMultiply(frameDuration, multiplier: Int32(index)), handler: handler) else {
                    timer.cancel()
                    completion?()
                    return
                }
            }
            timer.resume()
        }
    }

    public func stop() {
        state.withLock { state in
            state.generation += 1
            state.running = false
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        state.withLock { $0.running && $0.generation == generation }
    }

    /// The next frame index to emit, skipping ahead to `due` when pacing fell behind; nil once the run is complete.
    private func claimIndex(due: Int?) -> Int? {
        state.withLock { state -> Int? in
            if let maxFrames, state.emitted >= maxFrames { return nil }
            if let due, due > state.next {
                let target = loops ? due : min(due, framesPerPass)
                state.skipped += target - state.next
                state.next = target
            }
            guard loops || state.next < framesPerPass else { return nil }
            defer {
                state.next += 1
                state.emitted += 1
            }
            return state.next
        }
    }

    private func emit(_ index: Int, hostTime: CMTime, handler: FrameHandler) -> Bool {
        guard let buffer = try? pool.make() else { return false }
        convert(fileIndex: (index * frameStep) % fileFrameCount, into: buffer)
        handler(VideoFrame(pixelBuffer: buffer, presentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index)),
                           hostTime: hostTime))
        return true
    }

    private func convert(fileIndex: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2
        var info = conversion
        var destination = vImage_Buffer(data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer))
        data.withUnsafeBytes { raw in
            let luma = UnsafeMutableRawPointer(mutating: raw.baseAddress! + frameOffsets[fileIndex])
            let cb = luma + width * height
            let cr = cb + chromaWidth * chromaHeight
            var yPlane = vImage_Buffer(data: luma, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var cbPlane = vImage_Buffer(data: cb, height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth),
                                        rowBytes: chromaWidth)
            var crPlane = vImage_Buffer(data: cr, height: vImagePixelCount(chromaHeight), width: vImagePixelCount(chromaWidth),
                                        rowBytes: chromaWidth)
            let bgra: [UInt8] = [3, 2, 1, 0]
            vImageConvert_420Yp8_Cb8_Cr8ToARGB8888(&yPlane, &cbPlane, &crPlane, &destination, &info, bgra, 255,
                                                   vImage_Flags(kvImageNoFlags))
        }
    }
}
