import SwiftUI

struct StyleCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Style") {
            StylePicker(model: model, withShortcuts: true)
            Divider()
            Button("Previous Style") { model.selectAdjacent(-1) }
                .keyboardShortcut("[")
            Button("Next Style") { model.selectAdjacent(1) }
                .keyboardShortcut("]")
            Divider()
            Button("Add Style from Image…") { model.isShowingFileImporter = true }
                .keyboardShortcut("o")
        }
        CommandGroup(before: .toolbar) {
            PreviewToggles(model: model)
            Divider()
        }
    }
}

private struct PreviewToggles: View {
    @Bindable var model: AppModel

    var body: some View {
        Toggle("Mirror Preview", isOn: $model.preferences.mirrorPreview)
            .keyboardShortcut("m", modifiers: [.command, .shift])
        Toggle("Show Stats", isOn: $model.preferences.showStats)
            .keyboardShortcut("s", modifiers: [.command, .shift])
    }
}
