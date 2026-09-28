import AppKit
import StyleKit
import SwiftUI

private let tileSize = CGSize(width: 136, height: 86)
private let tileShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

struct StyleGallery: View {
    let model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    GalleryTile(title: "Original", subtitle: "No style", isSelected: !model.preferences.isStylized,
                                shortcut: "0") {
                        OriginalArtwork()
                    } action: {
                        model.select(Preferences.originalStyleID)
                    }
                    .id(Preferences.originalStyleID)
                    ForEach(Array(model.styles.enumerated()), id: \.element.id) { index, style in
                        StyleTile(model: model, style: style, shortcut: index < 9 ? "\(index + 1)" : nil)
                            .id(style.id)
                    }
                    AddStyleTile(model: model)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 14)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: model.preferences.styleID) { _, id in
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: model.isLibraryLoaded) {
                proxy.scrollTo(model.preferences.styleID, anchor: .center)
            }
        }
    }
}

private struct StyleTile: View {
    let model: AppModel
    let style: StyleInfo
    let shortcut: String?

    var body: some View {
        GalleryTile(title: style.title, subtitle: subtitle, isSelected: model.preferences.styleID == style.id,
                    shortcut: shortcut) {
            StyleThumbnail(model: model, style: style)
        } action: {
            model.select(style.id)
        }
        .contextMenu {
            if style.isCustom {
                Button("Remove Style", role: .destructive) { Task { await model.removeStyle(style) } }
            } else if let source = style.source.flatMap(URL.init(string:)) {
                Button("Open Painting Source") { NSWorkspace.shared.open(source) }
            }
        }
    }

    private var subtitle: String {
        guard let artist = style.artist else { return style.isCustom ? "Custom" : "" }
        return artist
    }
}

private struct StyleThumbnail: View {
    let model: AppModel
    let style: StyleInfo
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color(white: 0.16)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
        }
        .task(id: style.id) {
            guard let url = model.imageURL(for: style) else { return }
            image = await model.thumbnails.image(for: url)
        }
    }
}

private struct OriginalArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.28), Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "video")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.white.opacity(0.75))
        }
    }
}

private struct AddStyleTile: View {
    let model: AppModel
    @State private var isPresented = false

    var body: some View {
        GalleryTile(title: "Add Style", subtitle: "Image or link", isSelected: false, shortcut: nil) {
            ZStack {
                tileShape
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.secondary)
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
        } action: {
            isPresented = true
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            AddStyleForm(model: model, isPresented: $isPresented)
        }
    }
}

private struct AddStyleForm: View {
    let model: AppModel
    @Binding var isPresented: Bool
    @State private var link = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Style").font(.headline)
            Text("Use any painting, photo or pattern. StyleCam picks up its colors and brushwork.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                isPresented = false
                model.isShowingFileImporter = true
            } label: {
                Label("Choose Image…", systemImage: "photo.on.rectangle")
            }
            Divider()
            Text("Image link").font(.subheadline.weight(.medium))
            HStack {
                TextField("https://example.com/painting.jpg", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || model.isImporting)
            }
            Text("You can also drop an image anywhere on the window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func add() {
        let text = link
        Task {
            guard await model.addStyle(fromLink: text) else { return }
            link = ""
            isPresented = false
        }
    }
}

private struct GalleryTile<Artwork: View>: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let shortcut: String?
    @ViewBuilder let artwork: Artwork
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                artwork
                    .frame(width: tileSize.width, height: tileSize.height)
                    .clipShape(tileShape)
                    .overlay {
                        tileShape.strokeBorder(isSelected ? Color.accentColor : .white.opacity(isHovered ? 0.35 : 0.1),
                                           lineWidth: isSelected ? 3 : 1)
                    }
                    .overlay(alignment: .topLeading) {
                        if let shortcut {
                            Text("⌘\(shortcut)")
                                .font(.caption2.weight(.medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.black.opacity(0.45), in: Capsule())
                                .padding(6)
                                .opacity(isHovered || isSelected ? 1 : 0)
                        }
                    }
                    .shadow(color: isSelected ? Color.accentColor.opacity(0.45) : .clear, radius: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(subtitle.isEmpty ? " " : subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                .frame(width: tileSize.width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(subtitle.isEmpty ? title : "\(title), \(subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
