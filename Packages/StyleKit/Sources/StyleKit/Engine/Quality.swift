public struct ModelSize: Hashable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// Parses "WxH".
    public init?(_ string: String) {
        let parts = string.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(width: parts[0], height: parts[1])
    }

    public static let size480x270 = ModelSize(width: 480, height: 270)
    public static let size640x360 = ModelSize(width: 640, height: 360)
    public static let size960x540 = ModelSize(width: 960, height: 540)
    public static let size1280x720 = ModelSize(width: 1280, height: 720)
    public static let standard: [ModelSize] = [.size480x270, .size640x360, .size960x540, .size1280x720]

    public var description: String { "\(width)x\(height)" }
}

/// Where the transformer runs. `dual` keeps one instance on the GPU and one on the Neural Engine.
public enum EngineMode: String, Sendable, CaseIterable {
    case gpu
    case ane
    case dual
}

public struct Quality: Hashable, Sendable, CustomStringConvertible {
    public var size: ModelSize
    public var mode: EngineMode
    /// Makes `size` on `mode` the preferred configuration instead of a fixed one. A real-time pipeline then steps down
    /// to `size` on the Neural Engine and on to smaller sizes (down to 480x270) when frames miss their time budget, and
    /// keeps the GPU free in Low Power Mode, on battery, or when the Mac is hot.
    public var adaptive: Bool

    public init(size: ModelSize, mode: EngineMode, adaptive: Bool = false) {
        self.size = size
        self.mode = mode
        self.adaptive = adaptive
    }

    /// Leaves the GPU to other apps. At 30 fps on an otherwise idle Mac it is not faster than `balanced`: the Neural
    /// Engine clocks down between frames, and a paced 640x360 frame takes about twice its back-to-back time. While the
    /// GPU is busy it runs at its back-to-back speed.
    public static let fast = Quality(size: .size640x360, mode: .ane)
    public static let balanced = Quality(size: .size960x540, mode: .gpu)
    public static let max = Quality(size: .size1280x720, mode: .dual)
    public static let auto = Quality(size: .size960x540, mode: .gpu, adaptive: true)

    public var description: String { adaptive ? "auto, prefers \(size) \(mode.rawValue)" : "\(size) \(mode.rawValue)" }

    var fixed: Quality { Quality(size: size, mode: mode) }
}

public enum QualityPreset: String, Sendable, CaseIterable, Identifiable {
    case auto
    case fast
    case balanced
    case max

    public var id: String { rawValue }

    public var quality: Quality {
        switch self {
        case .auto: .auto
        case .fast: .fast
        case .balanced: .balanced
        case .max: .max
        }
    }
}
