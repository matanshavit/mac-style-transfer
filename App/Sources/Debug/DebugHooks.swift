#if DEBUG
import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import StyleKit
import UniformTypeIdentifiers

/// Launch arguments for checking the app without a camera or screen recording:
/// `-StyleCamVideoFile <file.y4m>` plays a video instead of the camera, `-StyleCamStyle <id>`, `-StyleCamShowStats YES`,
/// `-StyleCamWindowSize <W>x<H>`, `-StyleCamCameraAccess notDetermined|denied` pretends the camera permission is in
/// that state (and never opens the camera), `-StyleCamVirtualCameraOutput stylecam|obs` picks the virtual camera output,
/// and `-StyleCamSnapshot <file.png> [-StyleCamSnapshotDelay <seconds>]` writes
/// the window, the latest output frame and the main menu, then quits. Any of them keeps the saved settings untouched.
enum DebugHooks {
    private static var arguments: [String: Any] {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    static var isActive: Bool {
        arguments.keys.contains { $0.hasPrefix("StyleCam") }
    }

    static var videoFile: URL? {
        string("StyleCamVideoFile").map { URL(fileURLWithPath: $0) }
    }

    static var styleID: String? {
        string("StyleCamStyle")
    }

    static var showsStats: Bool {
        string("StyleCamShowStats").map { ["yes", "true", "1"].contains($0.lowercased()) } ?? false
    }

    static var windowSize: CGSize? {
        guard let size = string("StyleCamWindowSize").flatMap(ModelSize.init) else { return nil }
        return CGSize(width: size.width, height: size.height)
    }

    static var cameraAccess: AVAuthorizationStatus? {
        switch string("StyleCamCameraAccess") {
        case "notDetermined": .notDetermined
        case "denied": .denied
        default: nil
        }
    }

    static var virtualCameraTarget: VirtualCameraTarget? {
        string("StyleCamVirtualCameraOutput").flatMap(VirtualCameraTarget.init(rawValue:))
    }

    static var snapshotURL: URL? {
        string("StyleCamSnapshot").map { URL(fileURLWithPath: $0) }
    }

    static var snapshotDelay: Double {
        string("StyleCamSnapshotDelay").flatMap(Double.init) ?? 5
    }

    private static func string(_ key: String) -> String? {
        arguments[key].map { "\($0)" }
    }
}

/// cacheDisplay cannot draw the AVSampleBufferDisplayLayer, so the snapshot shows the latest frame in its place.
@MainActor
@Observable
final class DebugSnapshot {
    static let shared = DebugSnapshot()

    private(set) var previewFrame: NSImage?

    static func scheduleIfRequested(model: AppModel) {
        guard let url = DebugHooks.snapshotURL else { return }
        let recorder = LatestFrameRecorder()
        model.addDebugOutput(recorder)
        Task {
            try? await Task.sleep(for: .seconds(DebugHooks.snapshotDelay))
            let base = url.deletingPathExtension().lastPathComponent
            let frameURL = url.deletingLastPathComponent().appending(path: base + "-frame.png")
            do {
                if let frame = try recorder.write(to: frameURL) {
                    shared.previewFrame = NSImage(cgImage: frame, size: .zero)
                    try await Task.sleep(for: .milliseconds(300))
                } else {
                    FileHandle.standardError.write(Data("no frame was output\n".utf8))
                }
                try writeWindow(to: url)
                try writeMainMenu(to: url.deletingLastPathComponent().appending(path: base + "-menu.txt"))
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private static func writeWindow(to url: URL) throws {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView?.contains(PreviewView.self) == true }),
              let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SnapshotError("no main window")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotError("PNG encoding failed") }
        try data.write(to: url)
    }

    private static func writeMainMenu(to url: URL) throws {
        func lines(_ menu: NSMenu, depth: Int) -> [String] {
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            return menu.items.flatMap { item -> [String] in
                var line = String(repeating: "  ", count: depth) + (item.isSeparatorItem ? "---" : item.title)
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    line += "  " + [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
                        .filter { flags.contains($0.0) }.map(\.1).joined() + item.keyEquivalent.uppercased()
                }
                if item.state == .on { line += "  [on]" }
                if !item.isEnabled, !item.isSeparatorItem { line += "  (disabled)" }
                return [line] + (item.submenu.map { lines($0, depth: depth + 1) } ?? [])
            }
        }
        try (NSApp.mainMenu.map { lines($0, depth: 0) } ?? []).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct SnapshotError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class LatestFrameRecorder: FrameOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?

    func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        lock.withLock { latest = pixelBuffer }
    }

    func write(to url: URL) throws -> CGImage? {
        guard let frame = lock.withLock({ latest }) else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        guard let rendered = CIContext().createCGImage(image, from: image.extent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SnapshotError("cannot render the frame")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { throw SnapshotError("cannot write \(url.path)") }
        return rendered
    }
}

private extension NSView {
    func contains<View: NSView>(_ type: View.Type) -> Bool {
        self is View || subviews.contains { $0.contains(type) }
    }
}
#endif
