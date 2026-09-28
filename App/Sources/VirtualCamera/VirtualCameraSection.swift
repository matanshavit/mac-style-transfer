import AppKit
import StyleKit
import SwiftUI

struct VirtualCameraSection: View {
    let model: AppModel

    private var manager: ExtensionManager { model.extensionManager }

    private var isConnected: Bool {
        if case .connected = model.virtualCamera.status { true } else { false }
    }

    private var isInstalled: Bool {
        isConnected || manager.state == .activated
    }

    var body: some View {
        Section("Virtual Camera") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.title)
                }
            }
            if isConnected {
                LabeledContent("Apps using it", value: "\(model.virtualCamera.sourceClientCount ?? 0)")
            }
            ForEach(messages, id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if manager.state == .needsApproval {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                } else {
                    Button("Install") { manager.install() }
                        .disabled(isInstalled)
                }
                Button("Uninstall") { manager.uninstall() }
                    .disabled(!isInstalled && manager.state != .needsApproval && manager.state != .needsReboot)
            }
        }
    }

    private var status: (title: String, color: Color) {
        if isConnected { return ("Installed", .green) }
        return switch manager.state {
        case .activated: ("Installed", .green)
        case .idle: ("Not installed", .gray)
        case .needsApproval: ("Waiting for approval", .orange)
        case .needsReboot: ("Restart needed", .orange)
        case .failed: ("Install failed", .red)
        case .requiresApplicationsFolder: ("Not installed", .gray)
        }
    }

    private var messages: [String] {
        if isConnected {
            return model.virtualCamera.sourceClientCount ?? 0 > 0
                ? []
                : ["Choose “\(StyleCamIDs.deviceName)” as the camera in Zoom, Meet or FaceTime."]
        }
        var messages: [String] = []
        switch manager.state {
        case .activated:
            messages.append("Waiting for the camera to appear. If it does not, restart your Mac.")
        case .needsApproval:
            messages.append("Allow StyleCam in System Settings > General > Login Items & Extensions > Camera Extensions.")
        case .needsReboot:
            messages.append("Restart your Mac to finish.")
        case .failed(let error):
            messages.append(error)
        case .requiresApplicationsFolder:
            messages.append("macOS only installs the camera from an app in the Applications folder. Run “make install”, or move StyleCam there.")
        case .idle:
            break
        }
        if !ExtensionManager.hasDeveloperTeam {
            messages.append("This build is not signed with an Apple Developer team, so macOS will not install the camera. See docs/NEEDS_INPUT.md.")
        }
        return messages
    }
}
