import AppKit
import ImageIO

@MainActor
final class ThumbnailCache {
    nonisolated static let maxPixelSize = 360

    private var images: [URL: NSImage] = [:]

    func cached(_ url: URL) -> NSImage? {
        images[url]
    }

    func image(for url: URL) async -> NSImage? {
        if let image = images[url] { return image }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(url) }.value
        guard let decoded else { return nil }
        let image = NSImage(cgImage: decoded, size: .zero)
        images[url] = image
        return image
    }

    func remove(_ url: URL) {
        images[url] = nil
    }

    private nonisolated static func decode(_ url: URL) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
