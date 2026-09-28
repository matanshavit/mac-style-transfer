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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let clients = AppModel.shared.virtualCamera.sourceClientCount ?? 0
        guard clients > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "StyleCam is in use by \(clients) \(clients == 1 ? "app" : "apps")"
        alert.informativeText = "If you quit, \(clients == 1 ? "that app shows" : "those apps show") a placeholder instead of your video."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.disconnectVirtualCamera()
    }
}
