import SwiftUI

struct VirtualCameraSettingsView: View {
    @State private var extensionManager = ExtensionManager()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Install camera") { extensionManager.install() }
                Button("Uninstall camera") { extensionManager.uninstall() }
            }
            Text(status)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var status: String {
        switch extensionManager.state {
        case .idle: "Camera not installed"
        case .needsApproval: "Allow StyleCam in System Settings > General > Login Items & Extensions > Camera Extensions"
        case .activated: "Camera installed"
        case .needsReboot: "Restart your Mac to finish"
        case .failed(let message): "Camera install failed: \(message)"
        case .requiresApplicationsFolder: "Move StyleCam to the Applications folder to install the camera"
        }
    }
}
