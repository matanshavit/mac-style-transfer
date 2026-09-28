import AppKit
import StyleKit
import SwiftUI

struct VirtualCameraStatus {
    let title: String
    let color: Color
    let isInstalled: Bool

    @MainActor
    init(model: AppModel) {
        let clients = model.virtualCamera.sourceClientCount ?? 0
        if case .connected = model.virtualCamera.status {
            isInstalled = true
            color = .green
            title = clients == 0 ? "Ready" : "In use by \(clients) \(clients == 1 ? "app" : "apps")"
            return
        }
        isInstalled = model.extensionManager.state == .activated
        (title, color) = switch model.extensionManager.state {
        case .activated: ("Installed", .green)
        case .idle, .requiresApplicationsFolder: ("Not installed", .gray)
        case .needsApproval: ("Waiting for approval", .orange)
        case .needsReboot: ("Restart needed", .orange)
        case .failed: ("Install failed", .red)
        }
    }
}

struct VirtualCameraSection: View {
    let model: AppModel

    private var manager: ExtensionManager { model.extensionManager }

    private var canInstall: Bool {
        manager.state != .requiresApplicationsFolder && ExtensionManager.hasDeveloperTeam
    }

    var body: some View {
        let status = VirtualCameraStatus(model: model)
        Section("Virtual Camera") {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.title)
                }
            }
            ForEach(messages(status), id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if status.isInstalled {
                Button("Uninstall") { manager.uninstall() }
            } else if manager.state == .needsApproval {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                }
            } else if manager.state != .needsReboot {
                Button("Install") { manager.install() }
                    .disabled(!canInstall)
            }
        }
    }

    private func messages(_ status: VirtualCameraStatus) -> [String] {
        if case .connected = model.virtualCamera.status {
            return model.virtualCamera.sourceClientCount ?? 0 > 0
                ? []
                : ["Choose “\(StyleCamIDs.deviceName)” as the camera in Zoom, Meet or FaceTime."]
        }
        switch manager.state {
        case .activated:
            return ["Waiting for the camera to appear. If it does not, restart your Mac."]
        case .needsApproval:
            return ["Allow StyleCam in System Settings > General > Login Items & Extensions > Camera Extensions."]
        case .needsReboot:
            return ["Restart your Mac to finish."]
        case .failed(let error):
            return [error]
        case .idle, .requiresApplicationsFolder:
            var messages = ["Install the StyleCam camera to use this video in Zoom, Meet and FaceTime."]
            if manager.state == .requiresApplicationsFolder {
                #if DEBUG
                messages.append("macOS only installs the camera from an app in the Applications folder. Run “make install”.")
                #else
                messages.append("Move StyleCam to the Applications folder first.")
                #endif
            }
            if !ExtensionManager.hasDeveloperTeam {
                #if DEBUG
                messages.append("This build has no Apple Developer team, so macOS will not install the camera. See docs/NEEDS_INPUT.md.")
                #else
                messages.append("This copy of StyleCam is not signed by a developer, so macOS will not install the camera.")
                #endif
            }
            return messages
        }
    }
}
