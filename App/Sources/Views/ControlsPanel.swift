import StyleKit
import SwiftUI

struct ControlsPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            VirtualCameraSection(model: model)

            Section("Style") {
                if model.preferences.isStylized {
                    PercentSlider(title: "Strength", value: $model.preferences.strength)
                    PercentSlider(title: "Smoothing", value: $model.preferences.smoothing)
                    PercentSlider(title: "Detail", value: $model.preferences.detail)
                    Toggle("Preserve colors", isOn: $model.preferences.preserveColors)
                    Picker("Apply to", selection: $model.preferences.mask) {
                        Text("Everything").tag(MaskMode.everything)
                        Text("Background").tag(MaskMode.backgroundOnly)
                        Text("Me").tag(MaskMode.personOnly)
                    }
                } else {
                    Text("Pick a style to adjust it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Quality", selection: $model.preferences.quality) {
                    ForEach(QualityPreset.allCases) { preset in
                        Text(preset.rawValue.capitalized).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(Self.describe(model.preferences.quality.quality))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Quality")
            }

            Section("Camera") {
                if case .videoFile(let url) = model.source {
                    LabeledContent("Source", value: url.lastPathComponent)
                } else {
                    Picker("Camera", selection: $model.preferences.cameraID) {
                        Text("Automatic").tag(String?.none)
                        ForEach(model.cameras) { camera in
                            Text(camera.name).tag(String?.some(camera.id))
                        }
                        if let id = model.preferences.cameraID, !model.cameras.contains(where: { $0.id == id }) {
                            Text("Disconnected camera").tag(String?.some(id))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static func describe(_ quality: Quality) -> String {
        let device = switch quality.mode {
        case .gpu: "the GPU"
        case .ane: "the Neural Engine"
        case .dual: "the GPU and the Neural Engine"
        }
        return "Paints at \(quality.size) on \(device)."
    }
}

private struct PercentSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $value, in: 0...1) { Text(title) }
                .labelsHidden()
        }
    }
}
