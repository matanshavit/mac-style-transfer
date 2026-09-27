import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct StyleInfo: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var title: String
    public var artist: String?
    public var year: String?
    /// Image file name, relative to the catalog or custom styles directory.
    public var file: String
    public var source: String?
    public var isCustom: Bool

    public init(id: String, title: String, artist: String? = nil, year: String? = nil, file: String, source: String? = nil,
                isCustom: Bool = false) {
        self.id = id
        self.title = title
        self.artist = artist
        self.year = year
        self.file = file
        self.source = source
        self.isCustom = isCustom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        year = try container.decodeIfPresent(String.self, forKey: .year)
        file = try container.decode(String.self, forKey: .file)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
    }
}

public enum StyleLibraryError: Error, CustomStringConvertible {
    case unknownStyle(String)
    case unreadableImage(URL)
    case unwritableImage(URL)
    case noCustomDirectory

    public var description: String {
        switch self {
        case .unknownStyle(let id): "unknown style \(id)"
        case .unreadableImage(let url): "cannot read image \(url.path)"
        case .unwritableImage(let url): "cannot write image \(url.path)"
        case .noCustomDirectory: "the library has no directory for custom styles"
        }
    }
}

/// The built-in paintings from `catalog.json` plus custom styles saved as `<id>.png` + `<id>.json`.
/// Style vectors are computed on first use and cached in memory.
public actor StyleLibrary {
    public static let customImageMaxPixelSize = 1024

    public nonisolated let catalogDirectory: URL
    public nonisolated let customDirectory: URL?
    public nonisolated let builtInStyles: [StyleInfo]
    private let predictor: StylePredictor
    private var custom: [StyleInfo]
    private var vectors: [String: StyleVector] = [:]

    public init(catalogDirectory: URL, customDirectory: URL? = nil, predictor: StylePredictor) throws {
        self.catalogDirectory = catalogDirectory
        self.customDirectory = customDirectory
        self.predictor = predictor
        let catalog = try Data(contentsOf: catalogDirectory.appending(path: "catalog.json"))
        builtInStyles = try JSONDecoder().decode([StyleInfo].self, from: catalog)
        custom = customDirectory.map(Self.loadCustomStyles) ?? []
    }

    public var styles: [StyleInfo] { builtInStyles + custom }

    public var customStyles: [StyleInfo] { custom }

    public func style(id: String) -> StyleInfo? {
        styles.first { $0.id == id }
    }

    public nonisolated func imageURL(for style: StyleInfo) -> URL {
        (style.isCustom ? customDirectory ?? catalogDirectory : catalogDirectory).appending(path: style.file)
    }

    public func vector(for id: String) throws -> StyleVector {
        if let cached = vectors[id] { return cached }
        guard let style = style(id: id) else { throw StyleLibraryError.unknownStyle(id) }
        let vector = try predictor.vector(for: Self.loadImage(at: imageURL(for: style)))
        vectors[id] = vector
        return vector
    }

    public func addCustomStyle(imageAt url: URL, title: String? = nil) throws -> StyleInfo {
        try addCustomStyle(image: Self.loadImage(at: url), title: title ?? url.deletingPathExtension().lastPathComponent)
    }

    public func addCustomStyle(image: CGImage, title: String) throws -> StyleInfo {
        guard let customDirectory else { throw StyleLibraryError.noCustomDirectory }
        let id = "custom-" + UUID().uuidString.prefix(8).lowercased()
        let style = StyleInfo(id: id, title: title, file: "\(id).png", isCustom: true)
        let vector = try predictor.vector(for: image)
        try FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        try Self.writePNG(Self.limited(image), to: customDirectory.appending(path: style.file))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(style).write(to: customDirectory.appending(path: "\(id).json"), options: .atomic)
        custom.append(style)
        vectors[id] = vector
        return style
    }

    public func removeCustomStyle(id: String) throws {
        guard let customDirectory, let style = custom.first(where: { $0.id == id }) else { throw StyleLibraryError.unknownStyle(id) }
        for file in [style.file, "\(id).json"] {
            let url = customDirectory.appending(path: file)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        custom.removeAll { $0.id == id }
        vectors[id] = nil
    }

    /// Decodes an image with its EXIF orientation applied, downsampled so the long side is at most `maxPixelSize`.
    public static func loadImage(at url: URL, maxPixelSize: Int = customImageMaxPixelSize) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw StyleLibraryError.unreadableImage(url)
        }
        return image
    }

    private static func loadCustomStyles(from directory: URL) -> [StyleInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(StyleInfo.self, from: Data(contentsOf: $0)) }
            .sorted { $0.id < $1.id }
    }

    private static func limited(_ image: CGImage) -> CGImage {
        let longSide = max(image.width, image.height)
        guard longSide > customImageMaxPixelSize else { return image }
        let scale = Double(customImageMaxPixelSize) / Double(longSide)
        let width = Int(Double(image.width) * scale), height = Int(Double(image.height) * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw StyleLibraryError.unwritableImage(url)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StyleLibraryError.unwritableImage(url) }
    }
}
