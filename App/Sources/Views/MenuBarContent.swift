import AppKit
import SwiftUI

struct MenuBarContent: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Style: \(model.selectedTitle)")
        Divider()
        StylePicker(model: model)
        Divider()
        Button("Open StyleCam") {
            openWindow(id: StyleCamApp.mainWindowID)
            NSApp.activate()
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Divider()
        Button("Quit StyleCam") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Original and every style as checkmarked menu items. The first nine styles get Command-1 to Command-9.
struct StylePicker: View {
    let model: AppModel
    var withShortcuts = false

    var body: some View {
        Toggle("Original", isOn: selection(Preferences.originalStyleID))
            .keyboardShortcut(withShortcuts ? KeyboardShortcut("0") : nil)
        ForEach(Array(model.styles.enumerated()), id: \.element.id) { index, style in
            Toggle(style.title, isOn: selection(style.id))
                .keyboardShortcut(withShortcuts && index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil)
        }
    }

    private func selection(_ id: String) -> Binding<Bool> {
        Binding(get: { model.preferences.styleID == id }, set: { if $0 { model.select(id) } })
    }
}
