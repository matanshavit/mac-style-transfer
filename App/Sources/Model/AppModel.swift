import AppKit
import AVFoundation
import Observation
import os
import StyleKit

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Source: Equatable {
        case camera
        case videoFile(URL)
    }

    enum CaptureState: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    static let catalogDirectory = Bundle.main.resourceURL!.appending(path: "Styles", directoryHint: .isDirectory)
    static let customStylesDirectory = URL.applicationSupportDirectory
        .appending(path: "StyleCam/Styles", directoryHint: .isDirectory)
    /// Keeps the camera on briefly after it stops being needed, so hiding and showing the window does not restart it.
    static let stopDelay = Duration.seconds(2)

    let source: Source
    let preview = PreviewOutput()
    let extensionManager = ExtensionManager()
    let thumbnails = ThumbnailCache()

    var preferences: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }

    private(set) var styles: [StyleInfo] = []
    private(set) var isLibraryLoaded = false
    private(set) var cameras: [CameraDevice] = []
    private(set) var cameraAuthorization: AVAuthorizationStatus
    private(set) var captureState = CaptureState.stopped
    private(set) var stats: PipelineStats?
    private(set) var virtualCamera: VirtualCameraOutput.State
    private(set) var setupError: String?
    private(set) var isImporting = false
    var importError: String?
    var isShowingFileImporter = false

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let pipeline: StylePipeline?
    @ObservationIgnored private let camera = CameraCapture(excludedDeviceUIDs: [StyleCamIDs.deviceUID])
    @ObservationIgnored private let virtualCameraOutput = VirtualCameraOutput(
        deviceUID: StyleCamIDs.deviceUID, clientCountSelector: StyleCamIDs.sourceClientCountSelector)
    @ObservationIgnored private let awaitingFirstFrame = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private let logger = Logger(subsystem: "com.matanshavit.StyleCam", category: "app")
    @ObservationIgnored private var videoSource: Y4MFileSource?
    @ObservationIgnored private var library: StyleLibrary?
    @ObservationIgnored private var styleVector: StyleVector?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var styleTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var isMainWindowVisible = false
    @ObservationIgnored private var isPreviewAttached = false

    private init() {
        #if DEBUG
        source = DebugHooks.videoFile.map(Source.videoFile) ?? .camera
        defaults = DebugHooks.isActive ? nil : .standard
        var preferences = defaults.map(Preferences.init(defaults:)) ?? Preferences()
        if let styleID = DebugHooks.styleID { preferences.styleID = styleID }
        if DebugHooks.showsStats { preferences.showStats = true }
        self.preferences = preferences
        #else
        source = .camera
        defaults = .standard
        preferences = Preferences(defaults: .standard)
        #endif
        cameraAuthorization = source == .camera ? Self.currentCameraAuthorization : .authorized
        virtualCamera = virtualCameraOutput.state
        do {
            pipeline = try StylePipeline(modelStore: ModelStore(locations: [.bundle(.main)]))
        } catch {
            pipeline = nil
            setupError = "StyleCam cannot use this Mac's GPU: \(error)"
        }
        applyPipelineSettings()
        startObserving()
        loadTask = Task { await load() }
        virtualCameraOutput.connect()
        extensionManager.refresh()
    }

    var selectedStyle: StyleInfo? {
        styles.first { $0.id == preferences.styleID }
    }

    var selectedTitle: String {
        preferences.isStylized ? selectedStyle?.title ?? "Loading…" : "Original"
    }

    func waitUntilLoaded() async {
        await loadTask?.value
    }

    // MARK: - Styles

    func select(_ id: String) {
        guard id != preferences.styleID else { return }
        var next = preferences
        next.styleID = id
        if next.isStylized { next.lastStyleID = id }
        preferences = next
    }

    func selectAdjacent(_ offset: Int) {
        let ids = [Preferences.originalStyleID] + styles.map(\.id)
        let index = ids.firstIndex(of: preferences.styleID) ?? 0
        select(ids[(index + offset % ids.count + ids.count) % ids.count])
    }

    func toggleStyle() {
        if preferences.isStylized {
            select(Preferences.originalStyleID)
        } else if let id = preferences.lastStyleID, styles.contains(where: { $0.id == id }) {
            select(id)
        } else if let first = styles.first {
            select(first.id)
        }
    }

    func imageURL(for style: StyleInfo) -> URL? {
        library?.imageURL(for: style)
    }

    func addStyles(fromFiles urls: [URL]) async {
        await importStyle { library in
            var added: StyleInfo?
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                added = try await library.addCustomStyle(imageAt: url)
            }
            return added
        }
    }

    func addStyle(imageData data: Data, title: String) async {
        await importStyle { library in
            let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            try data.write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            return try await library.addCustomStyle(imageAt: file, title: title)
        }
    }

    /// Returns false when the text is not a web address.
    @discardableResult
    func addStyle(fromLink text: String) async -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            importError = "Enter a web address that starts with http:// or https://."
            return false
        }
        await importStyle { library in
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: file) }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ImportError.http(http.statusCode)
            }
            return try await library.addCustomStyle(imageAt: file, title: Self.title(for: url))
        }
        return true
    }

    func removeStyle(_ style: StyleInfo) async {
        guard let library, style.isCustom else { return }
        do {
            try await library.removeCustomStyle(id: style.id)
            thumbnails.remove(library.imageURL(for: style))
            styles = await library.styles
            if preferences.styleID == style.id { select(Preferences.originalStyleID) }
            if preferences.lastStyleID == style.id { preferences.lastStyleID = nil }
            StyleCamShortcuts.updateAppShortcutParameters()
        } catch {
            importError = "Could not remove \(style.title): \(error)"
        }
    }

    private enum ImportError: Error, CustomStringConvertible {
        case http(Int)

        var description: String {
            switch self {
            case .http(let status): "the server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))"
            }
        }
    }

    private func importStyle(_ add: (StyleLibrary) async throws -> StyleInfo?) async {
        guard let library else { return }
        isImporting = true
        defer { isImporting = false }
        var added: StyleInfo?
        do {
            added = try await add(library)
        } catch StyleLibraryError.unreadableImage {
            importError = "That file is not an image StyleCam can read."
        } catch {
            importError = "Could not add the style: \(error)"
        }
        styles = await library.styles
        if let added { select(added.id) }
        StyleCamShortcuts.updateAppShortcutParameters()
    }

    private static func title(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty || name == "/" ? url.host() ?? "Custom style" : name
    }

    // MARK: - Camera

    func mainWindowVisibilityChanged(_ visible: Bool) {
        guard visible != isMainWindowVisible else { return }
        isMainWindowVisible = visible
        updatePreviewAttachment()
        updateCapture()
    }

    func requestCameraAccess() async {
        _ = await CameraCapture.requestAccess()
        cameraAuthorization = Self.currentCameraAuthorization
        updateCapture()
    }

    func openCameraPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    func retryCapture() {
        if case .failed = captureState { captureState = .stopped }
        updateCapture()
    }

    private static var currentCameraAuthorization: AVAuthorizationStatus {
        #if DEBUG
        if let simulated = DebugHooks.cameraAccess { return simulated }
        #endif
        return CameraCapture.authorizationStatus
    }

    private var needsCapture: Bool {
        isMainWindowVisible || (virtualCamera.sourceClientCount ?? 0) > 0
    }

    private func updateCapture() {
        stopTask?.cancel()
        stopTask = nil
        if needsCapture {
            startCapture()
        } else if captureState != .stopped {
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.stopDelay)
                guard !Task.isCancelled else { return }
                self?.stopCapture()
            }
        }
    }

    private func startCapture() {
        guard let pipeline else { return }
        switch captureState {
        case .starting, .running: return
        case .stopped, .failed: break
        }
        let frameSource: any FrameSource
        switch source {
        case .camera:
            cameraAuthorization = Self.currentCameraAuthorization
            guard cameraAuthorization == .authorized else {
                captureState = .stopped
                return
            }
            frameSource = camera
        case .videoFile(let url):
            do {
                let video = try videoSource ?? Y4MFileSource(url: url, frameRate: 30, pacing: .realtime, loops: true)
                videoSource = video
                frameSource = video
            } catch {
                captureState = .failed("Cannot read \(url.lastPathComponent): \(error)")
                return
            }
        }
        awaitingFirstFrame.withLock { $0 = true }
        do {
            if source == .camera { try camera.selectDevice(id: preferences.cameraID) }
            try pipeline.start(source: frameSource)
            captureState = .starting
        } catch {
            captureState = .failed(Self.describe(error))
        }
    }

    private func stopCapture() {
        pipeline?.stop()
        preview.clear()
        captureState = .stopped
        stats = nil
    }

    private func firstFrameArrived() {
        if captureState == .starting { captureState = .running }
    }

    private func updatePreviewAttachment() {
        guard let pipeline, isPreviewAttached != isMainWindowVisible else { return }
        isPreviewAttached = isMainWindowVisible
        if isMainWindowVisible {
            pipeline.addOutput(preview)
        } else {
            pipeline.removeOutput(preview)
            preview.clear()
        }
    }

    private func camerasChanged(_ devices: [CameraDevice]) {
        cameras = devices
        switch captureState {
        case .failed:
            updateCapture()
        case .starting, .running:
            guard let active = camera.activeDevice, !devices.contains(where: { $0.id == active.id }) else { return }
            selectCamera()
        case .stopped:
            break
        }
    }

    private func selectCamera() {
        do {
            try camera.selectDevice(id: preferences.cameraID)
        } catch {
            pipeline?.stop()
            captureState = .failed(Self.describe(error))
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case CameraError.noDevice: "No camera is connected."
        case CameraError.notAuthorized: "StyleCam is not allowed to use the camera."
        default: String(describing: error)
        }
    }

    // MARK: - Setup

    private func startObserving() {
        guard let pipeline else { return }
        pipeline.addOutput(virtualCameraOutput)
        pipeline.onFrame = { [weak self, awaitingFirstFrame] _ in
            let first = awaitingFirstFrame.withLock { waiting in
                defer { waiting = false }
                return waiting
            }
            if first { Task { @MainActor in self?.firstFrameArrived() } }
        }
        Task { [weak self] in
            for await stats in pipeline.statsUpdates() {
                guard let self else { return }
                if captureState == .running { self.stats = stats }
            }
        }
        Task { [weak self, virtualCameraOutput] in
            for await state in virtualCameraOutput.stateUpdates {
                guard let self else { return }
                virtualCamera = state
                updateCapture()
            }
        }
        if source == .camera {
            cameras = camera.devices()
            observers = camera.observeDevices { [weak self] devices in self?.camerasChanged(devices) }
        }
        observers += [NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCameraAuthorization() }
        }]
    }

    /// Access can change in System Settings while the app runs.
    private func refreshCameraAuthorization() {
        let status = Self.currentCameraAuthorization
        guard source == .camera, status != cameraAuthorization else { return }
        cameraAuthorization = status
        updateCapture()
    }

    private func load() async {
        guard let pipeline else { return }
        async let prepared: Void = pipeline.prepare()
        do {
            let predictor = try await StylePredictor.load(from: pipeline.modelStore)
            let library = try StyleLibrary(catalogDirectory: Self.catalogDirectory, customDirectory: Self.customStylesDirectory,
                                           predictor: predictor)
            self.library = library
            styles = await library.styles
            if preferences.isStylized, !styles.contains(where: { $0.id == preferences.styleID }) {
                select(Preferences.originalStyleID)
            } else {
                resolveStyle()
            }
        } catch {
            setupError = "Could not load the styles: \(error)"
        }
        isLibraryLoaded = true
        StyleCamShortcuts.updateAppShortcutParameters()
        do {
            try await prepared
        } catch {
            logger.error("Could not prepare the style engine: \(String(describing: error))")
        }
    }

    // MARK: - Settings

    private func preferencesChanged(from old: Preferences) {
        guard preferences != old else { return }
        if let defaults { preferences.save(to: defaults) }
        if preferences.styleID != old.styleID {
            resolveStyle()
        } else {
            applyPipelineSettings()
        }
        if preferences.cameraID != old.cameraID, source == .camera, captureState != .stopped {
            selectCamera()
        }
    }

    private func resolveStyle() {
        styleTask?.cancel()
        let id = preferences.styleID
        guard preferences.isStylized, let library else {
            styleVector = nil
            applyPipelineSettings()
            return
        }
        styleTask = Task { [weak self] in
            let vector = try? await library.vector(for: id)
            guard let self, !Task.isCancelled else { return }
            styleVector = vector
            applyPipelineSettings()
        }
    }

    private func applyPipelineSettings() {
        let preferences = preferences
        let style = preferences.isStylized ? styleVector : nil
        pipeline?.updateSettings { settings in
            settings.style = style
            settings.quality = preferences.quality.quality
            settings.strength = Float(preferences.strength)
            settings.smoothing = Float(preferences.smoothing)
            settings.detail = Float(preferences.detail)
            settings.preserveColors = preferences.preserveColors
            settings.mask = preferences.mask
        }
    }

    #if DEBUG
    func addDebugOutput(_ output: any FrameOutput) {
        pipeline?.addOutput(output)
    }
    #endif
}
