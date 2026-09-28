import AVFoundation
import StyleKit
import SwiftUI

struct PreviewPane: View {
    let model: AppModel

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        ZStack {
            shape.fill(.black)
            StylePreview(output: model.preview, mirrored: model.preferences.mirrorPreview)
                .clipShape(shape)
            #if DEBUG
            if let frame = DebugSnapshot.shared.previewFrame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(x: model.preferences.mirrorPreview ? -1 : 1)
                    .clipShape(shape)
            }
            #endif
            PreviewStatus(model: model)
        }
        .overlay { shape.strokeBorder(.white.opacity(0.08)) }
        .overlay(alignment: .topTrailing) {
            if model.preferences.showStats, let stats = model.stats {
                StatsOverlay(stats: stats).padding(12)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }
}

private struct PreviewStatus: View {
    let model: AppModel

    var body: some View {
        if let error = model.setupError {
            StatusMessage(symbol: "exclamationmark.triangle", title: "StyleCam cannot start", message: error)
        } else if model.source == .camera, model.cameraAuthorization == .notDetermined {
            StatusMessage(symbol: "camera", title: "Allow camera access",
                          message: "StyleCam needs the camera to create the styled video.") {
                Button("Allow Camera Access") { Task { await model.requestCameraAccess() } }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.source == .camera, model.cameraAuthorization != .authorized {
            StatusMessage(symbol: "video.slash", title: "Camera access is off",
                          message: "Turn on StyleCam in System Settings > Privacy & Security > Camera.") {
                Button("Open Privacy Settings") { model.openCameraPrivacySettings() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            switch model.captureState {
            case .failed(let message):
                StatusMessage(symbol: "video.slash", title: model.captureFailureTitle, message: message) {
                    Button("Try Again") { model.retryCapture() }
                }
            case .interrupted:
                StatusMessage(symbol: "pause.circle", title: "Camera paused",
                              message: "macOS paused the camera. StyleCam continues when it is available again.")
            case .starting:
                ProgressView().controlSize(.large)
            case .stopped, .running:
                EmptyView()
            }
        }
    }
}

private struct StatusMessage<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            actions.padding(.top, 4)
        }
        .padding(24)
    }
}

extension StatusMessage where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}

private struct StatsOverlay: View {
    let stats: PipelineStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            row("Output", String(format: "%.0f fps", stats.outputFPS))
            if stats.engine != nil {
                row("Inference", String(format: "%.1f ms", stats.inferenceMillisecondsP50))
            }
            row("Latency", String(format: "%.0f ms", stats.latencyMillisecondsP50))
            row("Engine", stats.engine ?? "passthrough")
            if let adaptive = stats.adaptive {
                row("Auto", adaptive.reason.description)
            }
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(.primary)
        }
    }
}
