import CoreVideo
import Foundation
import StyleKit
import Synchronization

func runBench(_ arguments: Arguments) async throws {
    let store = ModelStore(directory: try arguments.url("models"))
    guard let size = ModelSize(try arguments.required("size")) else { throw UsageError(description: "--size expects WxH") }
    guard let mode = try arguments.choice("mode", as: EngineMode.self) else { throw UsageError(description: "missing --mode") }
    let iterations = try arguments.int("iters") ?? 300

    let loadStart = now()
    let engine = try await StyleEngine.load(store: store, size: size, mode: mode)
    let loadMilliseconds = (now() - loadStart) * 1000
    let inflight = try arguments.int("inflight") ?? engine.maxConcurrentFrames
    let result = try await Task.detached { try benchmark(engine, iterations: iterations, inflight: inflight) }.value

    let perDevice = result.frames.reduce(into: [ComputeDevice: [Double]]()) { $0[$1.device, default: []].append($1.milliseconds) }
    let devices = perDevice.keys.sorted { $0.rawValue > $1.rawValue }.map { device in
        let times = perDevice[device]!
        return "\(device.rawValue) \(times.count) frames p50 \(format(percentile(times, 0.5))) ms"
    }
    let all = result.frames.map(\.milliseconds)
    print("bench \(size) \(mode.rawValue): \(format(Double(iterations) / result.seconds, 1)) fps, "
        + "inference p50 \(format(percentile(all, 0.5))) p95 \(format(percentile(all, 0.95))) ms, inflight \(inflight), "
        + "load+warmup \(format(loadMilliseconds, 0)) ms; " + devices.joined(separator: ", "))
}

private struct BenchResult: Sendable {
    var seconds: Double
    var frames: [(device: ComputeDevice, milliseconds: Double)]
}

private final class BenchRecorder: Sendable {
    let frames = Mutex<[(device: ComputeDevice, milliseconds: Double)]>([])
    let failure = Mutex<String?>(nil)
}

private func benchmark(_ engine: StyleEngine, iterations: Int, inflight: Int) throws -> BenchResult {
    let input = try engine.makeInputBuffer()
    fillTestPattern(input)
    let style = StyleVector((0..<StyleVector.dimension).map { 0.3 * sin(Float($0) * 0.37) })
    let slots = DispatchSemaphore(value: inflight)
    let recorder = BenchRecorder()

    func submit(_ count: Int, record: Bool) {
        let group = DispatchGroup()
        for _ in 0..<count {
            slots.wait()
            group.enter()
            engine.stylize(input, style: style) { result in
                switch result {
                case .success(let frame):
                    if record { recorder.frames.withLock { $0.append((frame.device, frame.inferenceMilliseconds)) } }
                case .failure(let error):
                    recorder.failure.withLock { $0 = String(describing: error) }
                }
                slots.signal()
                group.leave()
            }
        }
        group.wait()
    }

    submit(20, record: false)
    let start = now()
    submit(iterations, record: true)
    let seconds = now() - start
    if let failure = recorder.failure.withLock({ $0 }) { throw UsageError(description: "prediction failed: \(failure)") }
    return BenchResult(seconds: seconds, frames: recorder.frames.withLock { $0 })
}

private func fillTestPattern(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    var seed: UInt32 = 12345
    for y in 0..<height {
        for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let pixel = base + y * rowBytes + x * 4
            pixel[0] = UInt8(truncatingIfNeeded: (x * 255 / max(width - 1, 1)) ^ Int(seed >> 28))
            pixel[1] = UInt8(truncatingIfNeeded: y * 255 / max(height - 1, 1))
            pixel[2] = UInt8(truncatingIfNeeded: (x + y) & 0xFF)
            pixel[3] = 255
        }
    }
}
