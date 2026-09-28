import CoreImage
import CoreVideo
import Foundation
import ImageIO
import StyleKit
import UniformTypeIdentifiers

/// Collects timings, temporal metrics and stills from the pipeline's frames, off the pipeline's queues.
///
/// Temporal metrics compare consecutive frames in full-range luma levels, split by the 9x9 mean input change:
/// static flicker is the mean output change where that is under 0.8 levels, and the moving change is the mean output
/// and input change where it is over 6. A whole-frame ratio would be dominated by real motion and input noise.
final class FrameAnalyzer: @unchecked Sendable {
    struct Report {
        var frames: Int
        var stylized: Int
        var timings: [FrameTimings]
        var staticFlicker: Double
        var staticFraction: Double
        var movingOutputChange: Double
        var movingInputChange: Double
        var movingFraction: Double
        /// Milliseconds between consecutive outputs.
        var outputIntervals: [Double]
        var stills: [URL]
    }

    private struct Luma {
        var width: Int
        var values: [UInt8]
    }

    private struct Change {
        var staticOutput: Double?
        var movingOutput: Double?
        var movingInput: Double?
        var staticFraction: Double
        var movingFraction: Double
    }

    private static let window = 4
    private static let staticThreshold = 0.8
    private static let movingThreshold = 6.0

    private let queue = DispatchQueue(label: "stylecam-cli.analyzer")
    private let stillsDirectory: URL?
    private let stillIndices: Set<Int>
    private let imageContext = CIContext()
    private var index = 0
    private var lastOutputTime: Double?
    private var previousOutput: Luma?
    private var previousInput: Luma?
    private var changes: [Change] = []
    private var report = Report(frames: 0, stylized: 0, timings: [], staticFlicker: 0, staticFraction: 0, movingOutputChange: 0,
                                movingInputChange: 0, movingFraction: 0, outputIntervals: [], stills: [])

    init(stillsDirectory: URL?, stillIndices: Set<Int>) throws {
        self.stillsDirectory = stillsDirectory
        self.stillIndices = stillIndices
        if let stillsDirectory { try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true) }
    }

    /// Call from the pipeline's `onFrame`, which runs when the frame is output.
    func add(_ frame: ProcessedFrame) {
        let time = now()
        queue.async { [self] in
            if let lastOutputTime { report.outputIntervals.append((time - lastOutputTime) * 1000) }
            lastOutputTime = time
            analyze(frame)
        }
    }

    func finish() async -> Report {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                report.staticFlicker = mean(changes.compactMap(\.staticOutput))
                report.staticFraction = mean(changes.map(\.staticFraction))
                report.movingOutputChange = mean(changes.compactMap(\.movingOutput))
                report.movingInputChange = mean(changes.compactMap(\.movingInput))
                report.movingFraction = mean(changes.map(\.movingFraction))
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
        if let previousOutput, let previousInput, output.width == input.width, output.values.count == input.values.count {
            changes.append(Self.change(output: output, previousOutput: previousOutput, input: input, previousInput: previousInput))
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

    private static func outputLuma(_ buffer: CVPixelBuffer) -> Luma {
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
        return Luma(width: width, values: luma)
    }

    private static func inputLuma(_ buffer: CVPixelBuffer) -> Luma {
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
        return Luma(width: width, values: luma)
    }

    /// Output luma is video range, so its changes are scaled to full-range levels.
    private static func change(output: Luma, previousOutput: Luma, input: Luma, previousInput: Luma) -> Change {
        let width = input.width, height = input.values.count / width
        let stride = width + 1
        var integral = [Int](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row = 0
            for x in 0..<width {
                row += abs(Int(input.values[y * width + x]) - Int(previousInput.values[y * width + x]))
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
            }
        }
        let r = window, area = Double((2 * r + 1) * (2 * r + 1))
        var staticCount = 0, movingCount = 0, staticOutput = 0, movingOutput = 0, movingInput = 0
        for y in r..<(height - r) {
            for x in r..<(width - r) {
                let sum = integral[(y + r + 1) * stride + x + r + 1] - integral[(y - r) * stride + x + r + 1]
                    - integral[(y + r + 1) * stride + x - r] + integral[(y - r) * stride + x - r]
                let meanChange = Double(sum) / area
                let i = y * width + x
                if meanChange < staticThreshold {
                    staticCount += 1
                    staticOutput += abs(Int(output.values[i]) - Int(previousOutput.values[i]))
                } else if meanChange > movingThreshold {
                    movingCount += 1
                    movingOutput += abs(Int(output.values[i]) - Int(previousOutput.values[i]))
                    movingInput += abs(Int(input.values[i]) - Int(previousInput.values[i]))
                }
            }
        }
        let pixels = Double((width - 2 * r) * (height - 2 * r))
        let videoScale = 255.0 / 219.0
        return Change(
            staticOutput: staticCount > 0 ? Double(staticOutput) / Double(staticCount) * videoScale : nil,
            movingOutput: movingCount > 0 ? Double(movingOutput) / Double(movingCount) * videoScale : nil,
            movingInput: movingCount > 0 ? Double(movingInput) / Double(movingCount) : nil,
            staticFraction: Double(staticCount) / pixels, movingFraction: Double(movingCount) / pixels)
    }
}
