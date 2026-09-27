import CoreImage
import CoreVideo
import Foundation
import ImageIO
import StyleKit
import UniformTypeIdentifiers

/// Collects timings, the flicker metric and stills from the pipeline's frames, off the pipeline's queues.
///
/// Flicker is mean_t(mean|out_t - out_t-1|) / mean_t(mean|in_t - in_t-1|) on full-range luma at output size.
final class FrameAnalyzer: @unchecked Sendable {
    struct Report {
        var frames: Int
        var stylized: Int
        var timings: [FrameTimings]
        var outputChange: Double
        var inputChange: Double
        var stills: [URL]

        var flicker: Double { inputChange > 0 ? outputChange / inputChange : 0 }
    }

    private let queue = DispatchQueue(label: "stylecam-cli.analyzer")
    private let stillsDirectory: URL?
    private let stillIndices: Set<Int>
    private let imageContext = CIContext()
    private var index = 0
    private var previousOutput: [UInt8]?
    private var previousInput: [UInt8]?
    private var outputChanges: [Double] = []
    private var inputChanges: [Double] = []
    private var report = Report(frames: 0, stylized: 0, timings: [], outputChange: 0, inputChange: 0, stills: [])

    init(stillsDirectory: URL?, stillIndices: Set<Int>) throws {
        self.stillsDirectory = stillsDirectory
        self.stillIndices = stillIndices
        if let stillsDirectory { try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true) }
    }

    func add(_ frame: ProcessedFrame) {
        queue.async { [self] in analyze(frame) }
    }

    func finish() async -> Report {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                report.outputChange = mean(outputChanges)
                report.inputChange = mean(inputChanges)
                continuation.resume(returning: report)
            }
        }
    }

    private func analyze(_ frame: ProcessedFrame) {
        report.frames += 1
        if frame.stylized { report.stylized += 1 }
        report.timings.append(frame.timings)

        let output = Self.outputLuma(frame.output)
        let input = Self.inputLuma(frame.source.pixelBuffer)
        if let previousOutput, let previousInput, output.count == input.count {
            outputChanges.append(Self.meanAbsoluteDifference(output, previousOutput) * 255 / 219)
            inputChanges.append(Self.meanAbsoluteDifference(input, previousInput))
        }
        previousOutput = output
        previousInput = input

        if let stillsDirectory, stillIndices.contains(index) {
            let name = String(format: "%04d", index)
            for (buffer, prefix) in [(frame.output, "out"), (frame.source.pixelBuffer, "in")] {
                let url = stillsDirectory.appending(path: "\(prefix)_\(name).png")
                if writePNG(buffer, to: url) { report.stills.append(url) }
            }
        }
        index += 1
    }

    private func writePNG(_ buffer: CVPixelBuffer, to url: URL) -> Bool {
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = imageContext.createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }

    private static func outputLuma(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0), height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: width * height)
        luma.withUnsafeMutableBufferPointer { destination in
            for y in 0..<height {
                (destination.baseAddress! + y * width).update(from: base + y * rowBytes, count: width)
            }
        }
        return luma
    }

    private static func inputLuma(_ buffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var luma = [UInt8](repeating: 0, count: width * height)
        luma.withUnsafeMutableBufferPointer { destination in
            for y in 0..<height {
                let row = base + y * rowBytes
                for x in 0..<width {
                    let b = Int(row[4 * x]), g = Int(row[4 * x + 1]), r = Int(row[4 * x + 2])
                    destination[y * width + x] = UInt8((77 * r + 150 * g + 29 * b + 128) >> 8)
                }
            }
        }
        return luma
    }

    private static func meanAbsoluteDifference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var total = 0
        a.withUnsafeBufferPointer { a in
            b.withUnsafeBufferPointer { b in
                for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
            }
        }
        return Double(total) / Double(a.count)
    }
}
