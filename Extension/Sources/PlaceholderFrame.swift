import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import VideoToolbox

final class PlaceholderFrame {
    private let template: CVPixelBuffer
    private let pool: CVPixelBufferPool
    private let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary

    init?(width: Int, height: Int) {
        let attributes = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: StyleCamVideo.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        var template: CVPixelBuffer?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess, let pool,
              CVPixelBufferCreate(kCFAllocatorDefault, width, height, StyleCamVideo.pixelFormat, attributes, &template) == kCVReturnSuccess,
              let template,
              let artwork = Self.renderArtwork(width: width, height: height)
        else { return nil }

        var session: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr, let session else {
            return nil
        }
        defer { VTPixelTransferSessionInvalidate(session) }
        guard VTPixelTransferSessionTransferImage(session, from: artwork, to: template) == noErr else { return nil }
        template.removeColorProfileAttachments()

        self.template = template
        self.pool = pool
    }

    func makeFrame() -> CVPixelBuffer? {
        var frame: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationAttributes, &frame) == kCVReturnSuccess,
              let frame
        else { return nil }

        CVPixelBufferLockBaseAddress(template, .readOnly)
        CVPixelBufferLockBaseAddress(frame, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(frame) {
            guard let source = CVPixelBufferGetBaseAddressOfPlane(template, plane),
                  let destination = CVPixelBufferGetBaseAddressOfPlane(frame, plane)
            else { continue }
            let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(template, plane)
            let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(frame, plane)
            let rowBytes = min(sourceRowBytes, destinationRowBytes)
            for row in 0..<CVPixelBufferGetHeightOfPlane(frame, plane) {
                memcpy(destination + row * destinationRowBytes, source + row * sourceRowBytes, rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        CVPixelBufferUnlockBaseAddress(template, .readOnly)
        CVBufferPropagateAttachments(template, frame)
        return frame
    }

    private static func renderArtwork(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let size = CGSize(width: width, height: height)
        let scale = size.height / 720
        context.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        drawCenteredLine(
            "StyleCam",
            font: CTFontCreateUIFontForLanguage(.emphasizedSystem, 96 * scale, nil),
            color: CGColor(gray: 1, alpha: 1),
            centerY: size.height * 0.56,
            in: context,
            width: size.width
        )
        drawCenteredLine(
            "Open StyleCam to start",
            font: CTFontCreateUIFontForLanguage(.system, 36 * scale, nil),
            color: CGColor(gray: 0.65, alpha: 1),
            centerY: size.height * 0.40,
            in: context,
            width: size.width
        )
        return buffer
    }

    private static func drawCenteredLine(_ text: String, font: CTFont?, color: CGColor, centerY: CGFloat, in context: CGContext, width: CGFloat) {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        if let font {
            attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX, y: centerY - bounds.midY)
        CTLineDraw(line, context)
    }
}
