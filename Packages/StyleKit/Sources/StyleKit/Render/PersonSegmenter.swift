import CoreVideo
import Foundation
import Metal
import Vision

public enum SegmentationQuality: String, Sendable, CaseIterable {
    case fast
    case balanced
}

/// Runs Vision person segmentation off the frame path. A frame is skipped while the previous one is still being
/// segmented, and the latest mask is reused until a newer one is ready.
final class PersonSegmenter: @unchecked Sendable {
    private let device: any MTLDevice
    private let queue = DispatchQueue(label: "StyleKit.PersonSegmenter", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var mask: (any MTLTexture)?
    private var handler = VNSequenceRequestHandler()
    private var request: VNGeneratePersonSegmentationRequest?

    init(device: any MTLDevice) {
        self.device = device
    }

    var latestMask: (any MTLTexture)? {
        lock.withLock { mask }
    }

    func submit(_ pixelBuffer: CVPixelBuffer, quality: SegmentationQuality) {
        let accepted = lock.withLock {
            guard !busy else { return false }
            busy = true
            return true
        }
        guard accepted else { return }
        let box = UncheckedBox(pixelBuffer)
        queue.async { [self] in
            let texture = segment(box.value, quality: quality)
            lock.withLock {
                if let texture { mask = texture }
                busy = false
            }
        }
    }

    private func segment(_ pixelBuffer: CVPixelBuffer, quality: SegmentationQuality) -> (any MTLTexture)? {
        let level: VNGeneratePersonSegmentationRequest.QualityLevel = quality == .fast ? .fast : .balanced
        if request?.qualityLevel != level {
            let created = VNGeneratePersonSegmentationRequest()
            created.qualityLevel = level
            created.outputPixelFormat = kCVPixelFormatType_OneComponent8
            request = created
            handler = VNSequenceRequestHandler()
        }
        guard let request, (try? handler.perform([request], on: pixelBuffer, orientation: .up)) != nil,
              let result = request.results?.first?.pixelBuffer else { return nil }
        return makeTexture(result)
    }

    private func makeTexture(_ buffer: CVPixelBuffer) -> (any MTLTexture)? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: buffer.width,
                                                                  height: buffer.height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, buffer.width, buffer.height), mipmapLevel: 0, withBytes: base,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return texture
    }
}
