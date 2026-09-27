public enum UpsamplingMode: String, Sendable, CaseIterable {
    case bilinear
    /// Bilinear plus camera detail through fast guided filter coefficients.
    case guided
}

public enum MaskMode: String, Sendable, CaseIterable {
    case everything
    case backgroundOnly = "background"
    case personOnly = "person"
}

public struct PipelineSettings: Sendable, Equatable {
    public var quality: Quality
    /// Nil outputs the camera unchanged.
    public var style: StyleVector?
    /// 0...1. Interpolates the style vector toward the live frame's own vector.
    public var strength: Float
    /// 0...1. Temporal smoothing of static areas.
    public var smoothing: Float
    public var upsampling: UpsamplingMode
    /// 0...2. How much camera detail the guided upsampling adds back.
    public var detail: Float
    public var preserveColors: Bool
    public var mask: MaskMode
    public var segmentationQuality: SegmentationQuality
    public var bypass: Bool

    public init(quality: Quality = .balanced, style: StyleVector? = nil, strength: Float = 1, smoothing: Float = 0.6,
                upsampling: UpsamplingMode = .guided, detail: Float = 1, preserveColors: Bool = false,
                mask: MaskMode = .everything, segmentationQuality: SegmentationQuality = .balanced, bypass: Bool = false) {
        self.quality = quality
        self.style = style
        self.strength = strength
        self.smoothing = smoothing
        self.upsampling = upsampling
        self.detail = detail
        self.preserveColors = preserveColors
        self.mask = mask
        self.segmentationQuality = segmentationQuality
        self.bypass = bypass
    }
}
