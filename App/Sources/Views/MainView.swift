import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: AppModel
    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PreviewPane(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                StyleGallery(model: model)
            }
            .frame(minWidth: 520)
            if model.preferences.showsControls {
                Divider()
                ControlsPanel(model: model)
                    .frame(width: 300)
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(minHeight: 460)
        .animation(.easeInOut(duration: 0.2), value: model.preferences.showsControls)
        .background(WindowVisibilityReader { model.mainWindowVisibilityChanged($0) })
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: Binding(get: { model.preferences.isStylized }, set: { _ in model.toggleStyle() })) {
                    Label("Style", systemImage: "paintbrush.pointed")
                }
                .help("Turn the style on or off")
                Toggle(isOn: $model.preferences.mirrorPreview) {
                    Label("Mirror Preview", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Mirror the preview. Other apps get the unmirrored video.")
                Toggle(isOn: $model.preferences.showStats) {
                    Label("Stats", systemImage: "gauge.with.dots.needle.33percent")
                }
                .help("Show frame rate and timing")
            }
            ToolbarItem {
                Button {
                    model.preferences.showsControls.toggle()
                } label: {
                    Label("Controls", systemImage: "sidebar.trailing")
                }
                .help(model.preferences.showsControls ? "Hide controls" : "Show controls")
            }
        }
        .navigationTitle("StyleCam")
        .navigationSubtitle(subtitle)
        .onDrop(of: StyleDrop.types, isTargeted: $isDropTargeted) { StyleDrop.add($0, to: model) }
        .overlay {
            if isDropTargeted { DropHighlight() }
        }
        .fileImporter(isPresented: $model.isShowingFileImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.addStyles(fromFiles: urls) }
            case .failure(let error): model.alert = .addFailed(error.localizedDescription)
            }
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
    }

    private var subtitle: String {
        guard let style = model.selectedStyle, model.preferences.isStylized else { return model.selectedTitle }
        return [style.title, style.artist].compactMap(\.self).joined(separator: " · ")
    }
}

private struct DropHighlight: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.12)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .padding(10)
            Label("Drop to add as a style", systemImage: "plus.circle.fill")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
        }
        .allowsHitTesting(false)
    }
}

enum StyleDrop {
    static let types: [UTType] = [.fileURL, .image, .url]

    @MainActor
    static func add(_ providers: [NSItemProvider], to model: AppModel) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await model.addStyles(fromFiles: [url]) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let title = provider.suggestedName ?? "Dropped image"
                _ = provider.loadDataRepresentation(for: .image) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await model.addStyle(imageData: data, title: title) }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if let failure = await model.addStyle(fromLink: url.absoluteString) { model.alert = .addFailed(failure) }
                    }
                }
            } else {
                continue
            }
            handled = true
        }
        return handled
    }
}
