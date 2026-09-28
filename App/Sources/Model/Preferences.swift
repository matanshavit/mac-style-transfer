import Foundation
import StyleKit

struct Preferences: Equatable {
    static let originalStyleID = "original"

    var styleID = "starry_night"
    /// The last painting picked, so toggling the style off and on restores it.
    var lastStyleID: String?
    var quality = QualityPreset.balanced
    var strength = Double(PipelineSettings().strength)
    var smoothing = Double(PipelineSettings().smoothing)
    var detail = Double(PipelineSettings().detail)
    var preserveColors = false
    var mask = MaskMode.everything
    /// Nil follows the system's preferred camera.
    var cameraID: String?
    var mirrorPreview = true
    var showStats = false

    var isStylized: Bool { styleID != Self.originalStyleID }
}

extension Preferences {
    private enum Key {
        static let style = "styleID"
        static let lastStyle = "lastStyleID"
        static let quality = "quality"
        static let strength = "strength"
        static let smoothing = "smoothing"
        static let detail = "detail"
        static let preserveColors = "preserveColors"
        static let mask = "mask"
        static let camera = "cameraID"
        static let mirrorPreview = "mirrorPreview"
        static let showStats = "showStats"
    }

    init(defaults: UserDefaults) {
        self.init()
        styleID = defaults.string(forKey: Key.style) ?? styleID
        lastStyleID = defaults.string(forKey: Key.lastStyle)
        quality = defaults.string(forKey: Key.quality).flatMap(QualityPreset.init(rawValue:)) ?? quality
        strength = defaults.object(forKey: Key.strength) as? Double ?? strength
        smoothing = defaults.object(forKey: Key.smoothing) as? Double ?? smoothing
        detail = defaults.object(forKey: Key.detail) as? Double ?? detail
        preserveColors = defaults.object(forKey: Key.preserveColors) as? Bool ?? preserveColors
        mask = defaults.string(forKey: Key.mask).flatMap(MaskMode.init(rawValue:)) ?? mask
        cameraID = defaults.string(forKey: Key.camera)
        mirrorPreview = defaults.object(forKey: Key.mirrorPreview) as? Bool ?? mirrorPreview
        showStats = defaults.object(forKey: Key.showStats) as? Bool ?? showStats
    }

    func save(to defaults: UserDefaults) {
        defaults.set(styleID, forKey: Key.style)
        defaults.set(lastStyleID, forKey: Key.lastStyle)
        defaults.set(quality.rawValue, forKey: Key.quality)
        defaults.set(strength, forKey: Key.strength)
        defaults.set(smoothing, forKey: Key.smoothing)
        defaults.set(detail, forKey: Key.detail)
        defaults.set(preserveColors, forKey: Key.preserveColors)
        defaults.set(mask.rawValue, forKey: Key.mask)
        defaults.set(cameraID, forKey: Key.camera)
        defaults.set(mirrorPreview, forKey: Key.mirrorPreview)
        defaults.set(showStats, forKey: Key.showStats)
    }
}
