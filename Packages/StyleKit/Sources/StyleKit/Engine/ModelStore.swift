import CoreML
import CryptoKit
import Foundation

public enum ModelStoreError: Error, CustomStringConvertible {
    case notFound(String)

    public var description: String {
        switch self {
        case .notFound(let names): "model not found: \(names)"
        }
    }
}

/// Finds Core ML models by name. Bundles hold `.mlmodelc` compiled by Xcode; directories may hold `.mlmodelc` or
/// `.mlpackage`, which is compiled once and cached until the package changes.
public actor ModelStore {
    public enum Location: Sendable {
        case bundle(Bundle)
        case directory(URL)
    }

    public static let predictorNames = ["MagentaPredictor_h256", "MagentaPredictor"]

    public static func transformerName(for network: StyleNetwork, size: ModelSize) -> String {
        "\(network.modelPrefix)_\(size.width)x\(size.height)"
    }

    public nonisolated let locations: [Location]
    public nonisolated let cacheDirectory: URL
    private var compiling: [URL: Task<URL, any Error>] = [:]

    public init(locations: [Location], cacheDirectory: URL? = nil) {
        self.locations = locations
        self.cacheDirectory = cacheDirectory ?? URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "StyleKit", directoryHint: .isDirectory)
            .appending(path: "CompiledModels", directoryHint: .isDirectory)
    }

    public init(directory: URL) {
        self.init(locations: [.directory(directory)])
    }

    public nonisolated func availableTransformerSizes(for network: StyleNetwork) -> [ModelSize] {
        ModelSize.standard.filter { locate(Self.transformerName(for: network, size: $0)) != nil }
    }

    /// URL of a compiled model, compiling an `.mlpackage` on first use.
    public func compiledModelURL(named names: [String]) async throws -> URL {
        for name in names {
            guard let found = locate(name) else { continue }
            if found.pathExtension == "mlmodelc" { return found }
            return try await compile(found, name: name)
        }
        throw ModelStoreError.notFound(names.joined(separator: " or "))
    }

    public nonisolated func loadModel(named names: [String], computeUnits: MLComputeUnits,
                                      lowPrecisionAccumulationOnGPU: Bool = false) async throws -> MLModel {
        let url = try await compiledModelURL(named: names)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = lowPrecisionAccumulationOnGPU
        return try await MLModel.load(contentsOf: url, configuration: configuration)
    }

    private nonisolated func locate(_ name: String) -> URL? {
        for location in locations {
            switch location {
            case .bundle(let bundle):
                if let url = bundle.url(forResource: name, withExtension: "mlmodelc") { return url }
            case .directory(let directory):
                for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
                    let url = directory.appending(path: "\(name).\(ext)")
                    if FileManager.default.fileExists(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    private func compile(_ source: URL, name: String) async throws -> URL {
        let destination = cacheDirectory.appending(path: "\(name)-\(try Self.fingerprint(source)).mlmodelc")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        if let task = compiling[destination] { return try await task.value }
        let cacheDirectory = cacheDirectory
        let task = Task<URL, any Error> {
            let compiled = try await MLModel.compileModel(at: source)
            let files = FileManager.default
            try files.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            for stale in try files.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            where stale.lastPathComponent.hasPrefix("\(name)-") {
                try? files.removeItem(at: stale)
            }
            try files.moveItem(at: compiled, to: destination)
            return destination
        }
        compiling[destination] = task
        defer { compiling[destination] = nil }
        return try await task.value
    }

    /// Changes whenever any file in the package changes size or modification date.
    private static func fingerprint(_ url: URL) throws -> String {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var entries: [String] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
        let items = (enumerator?.allObjects as? [URL] ?? []) + [url]
        for item in items {
            let values = try item.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let path = item.path.replacingOccurrences(of: url.path, with: "")
            entries.append("\(path):\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)")
        }
        let digest = SHA256.hash(data: Data(entries.sorted().joined(separator: "\n").utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
