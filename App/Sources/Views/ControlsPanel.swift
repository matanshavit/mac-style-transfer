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
                    Toggle(isOn: steadyBrushwork) {
                        Text("Steady brushwork")
                        Text(steadyBrushworkNote)
                    }
                    .disabled(model.steadySizes.isEmpty)
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

    private var steadyBrushwork: Binding<Bool> {
        Binding {
            model.network == .steady
        } set: { steady in
            model.preferences.network = steady ? .steady : .classic
        }
    }

    private var steadyBrushworkNote: String {
        let missing = ModelSize.standard.filter { !model.steadySizes.contains($0) }
        if missing.count == ModelSize.standard.count { return "This build has no steady models." }
        let note = "Less shimmer on still areas and when you move. Slightly softer fine texture."
        guard !missing.isEmpty else { return note }
        return note + " Classic runs at \(missing.map(\.description).formatted(.list(type: .and)))."
    }

    private static func describe(_ quality: Quality) -> String {
        if quality.adaptive {
            return "Moves between the GPU and the Neural Engine to keep the video smooth when the Mac is busy, hot or on battery."
        }
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
