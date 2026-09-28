import AppIntents
import StyleKit

struct StyleEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "StyleCam Style"
    static let defaultQuery = StyleQuery()

    let id: String
    let title: String
    let artist: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: artist.map { "\($0)" })
    }

    static let original = StyleEntity(id: Preferences.originalStyleID, title: "Original", artist: "No style")

    init(id: String, title: String, artist: String?) {
        self.id = id
        self.title = title
        self.artist = artist
    }

    init(_ style: StyleInfo) {
        self.init(id: style.id, title: style.title, artist: style.artist ?? (style.isCustom ? "Custom" : nil))
    }
}

struct StyleQuery: EnumerableEntityQuery {
    @MainActor
    func allEntities() async throws -> [StyleEntity] {
        let model = AppModel.shared
        await model.waitUntilLoaded()
        return [.original] + model.styles.map(StyleEntity.init)
    }

    @MainActor
    func entities(for identifiers: [StyleEntity.ID]) async throws -> [StyleEntity] {
        try await allEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [StyleEntity] {
        try await allEntities()
    }
}

struct SetStyleIntent: AppIntent {
    static let title: LocalizedStringResource = "Set StyleCam Style"
    static let description = IntentDescription("Changes the painting style of the StyleCam camera, or turns it off with Original.")

    @Parameter(title: "Style")
    var style: StyleEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Set StyleCam style to \(\.$style)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.waitUntilLoaded()
        model.select(style.id)
        return .result(dialog: "StyleCam is now \(model.selectedTitle).")
    }
}

struct ToggleStyleIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle StyleCam Style"
    static let description = IntentDescription("Turns the StyleCam painting style off, or back on to the last style.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        await model.waitUntilLoaded()
        model.toggleStyle()
        return .result(dialog: model.preferences.isStylized ? "StyleCam style on: \(model.selectedTitle)." : "StyleCam style off.")
    }
}

struct StyleCamShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetStyleIntent(),
            phrases: ["Set \(.applicationName) style to \(\.$style)", "Set \(.applicationName) style", "Change \(.applicationName) style"],
            shortTitle: "Set Style",
            systemImageName: "paintpalette"
        )
        AppShortcut(
            intent: ToggleStyleIntent(),
            phrases: ["Toggle \(.applicationName) style", "Turn \(.applicationName) style on or off"],
            shortTitle: "Toggle Style",
            systemImageName: "camera.filters"
        )
    }
}
