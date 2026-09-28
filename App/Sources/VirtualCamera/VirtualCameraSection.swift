import AppKit
import StyleKit
import SwiftUI

struct VirtualCameraStatus {
    let title: String
    let color: Color

    @MainActor
    init(model: AppModel) {
        let clients = model.virtualCamera.sourceClientCount ?? 0
        switch (model.preferences.virtualCameraTarget, model.virtualCamera.status) {
        case (.obs, .connected):
            (title, color) = ("Connected to OBS", .green)
        case (.obs, .busy):
            (title, color) = ("OBS is open", .orange)
        case (.obs, .error):
            (title, color) = ("Can’t connect to OBS", .red)
        case (.obs, _):
            (title, color) = ("OBS not found", .gray)
        case (.styleCam, .connected):
            (title, color) = (clients == 0 ? "Ready" : "In use by \(clients) \(clients == 1 ? "app" : "apps")", .green)
        case (.styleCam, .error):
            (title, color) = ("Can’t connect", .red)
        case (.styleCam, _):
            (title, color) = switch model.extensionManager.state {
            case .activated: ("Installed", .green)
            case .idle, .requiresApplicationsFolder: ("Not installed", .gray)
            case .needsApproval: ("Waiting for approval", .orange)
            case .needsReboot: ("Restart needed", .orange)
            case .failed: ("Install failed", .red)
            }
        }
    }
}

struct VirtualCameraSection: View {
    @Bindable var model: AppModel

    private var manager: ExtensionManager { model.extensionManager }

    private var isConnected: Bool {
        if case .connected = model.virtualCamera.status { return true }
        return false
    }

    private var isOBSMissing: Bool {
        [.notFound, .disconnected].contains(model.virtualCamera.status)
    }

    private var canInstall: Bool {
        manager.state != .requiresApplicationsFolder && ExtensionManager.hasDeveloperTeam
    }

    var body: some View {
        let status = VirtualCameraStatus(model: model)
        Section("Virtual Camera") {
            Picker("Output", selection: $model.preferences.virtualCameraTarget) {
                Text("StyleCam camera").tag(VirtualCameraTarget.styleCam)
                Text("OBS (experimental)").tag(VirtualCameraTarget.obs)
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle().fill(status.color).frame(width: 8, height: 8)
                    Text(status.title)
                }
            }
            ForEach(messages, id: \.self) { message in
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.preferences.virtualCameraTarget {
            case .obs:
                if isOBSMissing {
                    Link("Download OBS", destination: OBSVirtualCamera.downloadURL)
                }
            case .styleCam:
                if isConnected || manager.state == .activated {
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
    }

    private var messages: [String] {
        switch model.preferences.virtualCameraTarget {
        case .obs: obsMessages
        case .styleCam: styleCamMessages
        }
    }

    private var obsMessages: [String] {
        switch model.virtualCamera.status {
        case .connected:
            [
                "Sending to OBS Virtual Camera. The camera stays on while this is selected, even with the window closed.",
                "Choose “\(OBSVirtualCamera.deviceName)” in Zoom, Meet or FaceTime. While OBS is open, StyleCam leaves its camera to OBS.",
            ]
        case .busy:
            ["StyleCam leaves OBS Virtual Camera to OBS while OBS is open. Quit OBS to send this video there."]
        case .error(let error):
            [error]
        case .notFound, .disconnected:
            [
                "Sends the video to OBS Virtual Camera, which works without StyleCam’s own camera. To set it up:",
                """
                1. Install OBS Studio in the Applications folder.
                2. Open OBS and click Start Virtual Camera.
                3. Allow OBS in System Settings > General > Login Items & Extensions > Camera Extensions.
                4. Quit OBS. StyleCam connects by itself, then keeps the camera on, even with the window closed.
                """,
            ]
        }
    }

    private var styleCamMessages: [String] {
        if isConnected {
            return model.virtualCamera.sourceClientCount ?? 0 > 0
                ? []
                : ["Choose “\(StyleCamIDs.deviceName)” as the camera in Zoom, Meet or FaceTime."]
        }
        if case .error(let error) = model.virtualCamera.status {
            return ["Another app may be sending to the StyleCam camera. StyleCam keeps trying.", error]
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
                messages.append("Without it, you can send the video to OBS Virtual Camera instead.")
            }
            return messages
        }
    }
}
