import CoreVideo
import Foundation

public enum PixelBufferError: Error, CustomStringConvertible {
    case poolCreation(CVReturn)
    case allocation(CVReturn)
    case textureCreation(CVReturn)

    public var description: String {
        switch self {
        case .poolCreation(let status): "CVPixelBufferPoolCreate failed (\(status))"
        case .allocation(let status): "CVPixelBufferPoolCreatePixelBuffer failed (\(status))"
        case .textureCreation(let status): "CVMetalTextureCacheCreateTextureFromImage failed (\(status))"
        }
    }
}

final class PixelBufferPool: @unchecked Sendable {
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int, pixelFormat: OSType, minimumBufferCount: Int = 3) throws {
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let poolAttributes: [CFString: Any] = [kCVPixelBufferPoolMinimumBufferCountKey: minimumBufferCount]
        var created: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, poolAttributes as CFDictionary, bufferAttributes as CFDictionary, &created)
        guard status == kCVReturnSuccess, let created else { throw PixelBufferError.poolCreation(status) }
        pool = created
    }

    func make() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PixelBufferError.allocation(status) }
        return buffer
    }
}

extension CVPixelBuffer {
    var width: Int { CVPixelBufferGetWidth(self) }
    var height: Int { CVPixelBufferGetHeight(self) }
}

enum NV12Attachments {
    /// Clients rebuild a color space per frame when ICC or primaries attachments are present, so only the matrix is set.
    static func apply(to buffer: CVPixelBuffer) {
        CVBufferRemoveAllAttachments(buffer)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
    }
}
