import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Toggle("Open StyleCam at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: setLaunchAtLogin))
                if status == .requiresApproval {
                    Text("Allow StyleCam in System Settings > General > Login Items & Extensions.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text("StyleCam keeps running in the menu bar after you close its window, so the virtual camera stays available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        status = SMAppService.mainApp.status
    }
}
