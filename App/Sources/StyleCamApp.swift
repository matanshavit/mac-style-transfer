import AppKit
import SwiftUI

@main
struct StyleCamApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        #if DEBUG
        DebugSnapshot.scheduleIfRequested(model: model)
        #endif
    }

    var body: some Scene {
        Window("StyleCam", id: Self.mainWindowID) {
            MainView(model: model)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified)
        .commands { StyleCommands(model: model) }

        MenuBarExtra("StyleCam", systemImage: "camera.filters") {
            MenuBarContent(model: model)
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The virtual camera needs the app running after its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
