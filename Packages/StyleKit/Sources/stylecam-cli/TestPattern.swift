import CoreVideo
import Foundation

final class TestPattern {
    private static let background: Int32 = 32
    private static let foreground: Int32 = 235
    private static let segments: [UInt8] = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F]

    private let width: Int
    private let height: Int
    private let pool: CVPixelBufferPool

    init?(width: Int, height: Int) {
        let attributes = [
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess, let pool else { return nil }
        self.width = width
        self.height = height
        self.pool = pool
    }

    func makeFrame(index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)

        let barWidth = width / 16
        let barX = (index * 8) % (width - barWidth)
        for row in 0..<height {
            let line = luma + row * lumaRowBytes
            memset(line, Self.background, width)
            memset(line + barX, Self.foreground, barWidth)
        }
        for row in 0..<height / 2 {
            memset(chroma + row * chromaRowBytes, 128, width)
        }

        let digitWidth = 40
        let digitHeight = 72
        let spacing = 16
        let digits = String(format: "%06d", index % 1_000_000).compactMap(\.wholeNumberValue)
        let counterWidth = digits.count * (digitWidth + spacing) - spacing
        fill(x: 24, y: 24, width: counterWidth + 32, height: digitHeight + 32, value: Self.background, luma: luma, rowBytes: lumaRowBytes)
        for (position, digit) in digits.enumerated() {
            drawDigit(digit, x: 40 + position * (digitWidth + spacing), y: 40, width: digitWidth, height: digitHeight, luma: luma, rowBytes: lumaRowBytes)
        }
        return buffer
    }

    private func drawDigit(_ digit: Int, x: Int, y: Int, width: Int, height: Int, luma: UnsafeMutableRawPointer, rowBytes: Int) {
        let thickness = 8
        let half = height / 2
        let rects = [
            (x, y, width, thickness),
            (x + width - thickness, y, thickness, half),
            (x + width - thickness, y + half, thickness, half),
            (x, y + height - thickness, width, thickness),
            (x, y + half, thickness, half),
            (x, y, thickness, half),
            (x, y + half - thickness / 2, width, thickness),
        ]
        for (segment, rect) in rects.enumerated() where Self.segments[digit] & (1 << segment) != 0 {
            fill(x: rect.0, y: rect.1, width: rect.2, height: rect.3, value: Self.foreground, luma: luma, rowBytes: rowBytes)
        }
    }

    private func fill(x: Int, y: Int, width: Int, height: Int, value: Int32, luma: UnsafeMutableRawPointer, rowBytes: Int) {
        for row in y..<(y + height) {
            memset(luma + row * rowBytes + x, value, width)
        }
    }
}
