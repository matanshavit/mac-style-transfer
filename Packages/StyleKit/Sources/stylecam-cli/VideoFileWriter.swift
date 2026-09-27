import AVFoundation
import Foundation
import StyleKit

final class VideoFileWriter: FrameOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "stylecam-cli.writer")
    private var started = false
    private var failure: (any Error)?
    private(set) var framesWritten = 0

    init(url: URL, width: Int, height: Int, codec: AVVideoCodecType, realtime: Bool) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ],
        ])
        input.expectsMediaDataInRealTime = realtime
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? UsageError(description: "cannot write \(url.path)") }
    }

    func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        let box = UncheckedBox(value: pixelBuffer)
        queue.async { [self] in
            guard failure == nil else { return }
            if !started {
                writer.startSession(atSourceTime: time)
                started = true
            }
            while !input.isReadyForMoreMediaData && writer.status == .writing { usleep(500) }
            if adaptor.append(box.value, withPresentationTime: time) {
                framesWritten += 1
            } else {
                failure = writer.error
            }
        }
    }

    func finish() async throws {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        if let failure { throw failure }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? UsageError(description: "writing failed") }
    }
}
