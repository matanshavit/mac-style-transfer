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
        case interrupted
        case failed(String)
    }

    struct AlertMessage: Equatable {
        let title: String
        let message: String

        static func addFailed(_ message: String) -> AlertMessage {
            AlertMessage(title: "Couldn’t Add Style", message: message)
        }
    }

    static let catalogDirectory = Bundle.main.resourceURL!.appending(path: "Styles", directoryHint: .isDirectory)
    static let customStylesDirectory = URL.applicationSupportDirectory
        .appending(path: "StyleCam/Styles", directoryHint: .isDirectory)
    /// Keeps the camera on briefly after it stops being needed, so hiding and showing the window does not restart it.
    static let stopDelay = Duration.seconds(2)
    static let startTimeout = Duration.seconds(10)
    nonisolated static let maxDownloadBytes = 50_000_000

    let source: Source
    let preview = PreviewOutput()
    let extensionManager = ExtensionManager()
    let thumbnails = ThumbnailCache()
    /// Sizes bundled with a steady model. The others run classic.
    let steadySizes: [ModelSize]

    var preferences: Preferences {
        didSet { preferencesChanged(from: oldValue) }
    }

    private(set) var styles: [StyleInfo] = []
    private(set) var isLibraryLoaded = false
    private(set) var cameras: [CameraDevice] = []
    private(set) var cameraAuthorization: AVAuthorizationStatus
    private(set) var captureState = CaptureState.stopped {
        didSet { obsOutput.holdsSink = captureState == .running }
    }
    private(set) var stats: PipelineStats?
    private(set) var virtualCamera: VirtualCameraOutput.State
    private(set) var setupError: String?
    private var importCount = 0
    var alert: AlertMessage?
    var isShowingFileImporter = false

    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let pipeline: StylePipeline?
    @ObservationIgnored private let camera = CameraCapture(excludedDeviceUIDs: [StyleCamIDs.deviceUID, OBSVirtualCamera.deviceUID])
    @ObservationIgnored private let styleCamOutput = VirtualCameraOutput(
        deviceUID: StyleCamIDs.deviceUID, clientCountSelector: StyleCamIDs.sourceClientCountSelector)
    @ObservationIgnored private let obsOutput = VirtualCameraOutput(
        deviceUID: OBSVirtualCamera.deviceUID, fallbackDeviceName: OBSVirtualCamera.deviceName,
        yieldsWhile: { OBSVirtualCamera.isAppRunning })
    @ObservationIgnored private let awaitingFirstFrame = OSAllocatedUnfairLock(initialState: false)
    @ObservationIgnored private let logger = Logger(subsystem: "com.matanshavit.StyleCam", category: "app")
    @ObservationIgnored private var videoSource: Y4MFileSource?
    @ObservationIgnored private var library: StyleLibrary?
    @ObservationIgnored private var styleVector: StyleVector?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var styleTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var startTimeoutTask: Task<Void, Never>?
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
        if let target = DebugHooks.virtualCameraTarget { preferences.virtualCameraTarget = target }
        self.preferences = preferences
        #else
        source = .camera
        defaults = .standard
        let preferences = Preferences(defaults: .standard)
        self.preferences = preferences
        #endif
        cameraAuthorization = source == .camera ? Self.currentCameraAuthorization : .authorized
        virtualCamera = (preferences.virtualCameraTarget == .obs ? obsOutput : styleCamOutput).state
        let modelStore = ModelStore(locations: [.bundle(.main)])
        steadySizes = modelStore.availableTransformerSizes(for: .steady)
        do {
            pipeline = try StylePipeline(modelStore: modelStore)
        } catch {
            pipeline = nil
            setupError = "StyleCam cannot use this Mac’s GPU. " + Self.describe(error)
        }
        applyPipelineSettings()
        startObserving()
        loadTask = Task { await load() }
        obsOutput.holdsSink = false
        virtualCameraOutput.connect()
        extensionManager.refresh()
    }

    /// Classic when the build has no steady models, whatever the preference.
    var network: StyleNetwork {
        steadySizes.isEmpty ? .classic : preferences.network
    }

    /// OBS's device has no client count, so the camera stays on while StyleCam is connected to it. It also stays on
    /// after a failed start, so the output keeps retrying.
    private var keepsCameraOnForOBS: Bool {
        guard preferences.virtualCameraTarget == .obs else { return false }
        switch virtualCamera.status {
        case .connected, .error: return true
        case .disconnected, .notFound, .busy: return false
        }
    }

    private var virtualCameraOutput: VirtualCameraOutput {
        preferences.virtualCameraTarget == .obs ? obsOutput : styleCamOutput
    }

    /// Stops the sink before quitting rather than relying on macOS to stop it for an app that exited.
    func disconnectVirtualCamera() {
        virtualCameraOutput.disconnect()
    }

    var selectedStyle: StyleInfo? {
        styles.first { $0.id == preferences.styleID }
    }

    var isImporting: Bool {
        importCount > 0
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
        let failure = await importStyle { library in
            var added: StyleInfo?
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                added = try await library.addCustomStyle(imageAt: url)
            }
            return added
        }
        if let failure { alert = .addFailed(failure) }
    }

    func addStyle(imageData data: Data, title: String) async {
        if let failure = await importStyle({ library in try await Self.add(data, title: title, to: library) }) {
            alert = .addFailed(failure)
        }
    }

    /// Returns why the style could not be added, or nil once it is added and selected. Plain http links are fetched
    /// over https, because App Transport Security blocks http.
    func addStyle(fromLink text: String) async -> String? {
        guard let url = Self.webURL(text) else { return "Enter a link that starts with https://." }
        return await importStyle { library in
            try await Self.add(Self.download(url), title: Self.title(for: url), to: library)
        }
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
            alert = AlertMessage(title: "Couldn’t Remove Style", message: Self.describe(error))
        }
    }

    private enum ImportError: Error {
        case http(Int)
        case notImage(webPage: Bool)
        case tooLarge
        case libraryUnavailable

        var message: String {
            switch self {
            case .http(let status):
                "The server answered \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."
            case .notImage(webPage: true): "That link opens a web page, not an image. Use a direct link to the image file."
            case .notImage(webPage: false): "That link is not an image."
            case .tooLarge: "That image is larger than \(maxDownloadBytes / 1_000_000) MB."
            case .libraryUnavailable: "StyleCam could not load its styles."
            }
        }
    }

    private nonisolated static let downloadSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private func importStyle(_ add: (StyleLibrary) async throws -> StyleInfo?) async -> String? {
        importCount += 1
        defer { importCount -= 1 }
        await loadTask?.value
        var failure: String?
        do {
            guard let library else { throw ImportError.libraryUnavailable }
            let added = try await add(library)
            styles = await library.styles
            if let added { select(added.id) }
        } catch {
            failure = Self.describe(error)
            if let library { styles = await library.styles }
        }
        StyleCamShortcuts.updateAppShortcutParameters()
        return failure
    }

    private nonisolated static func add(_ data: Data, title: String, to library: StyleLibrary) async throws -> StyleInfo {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try await library.addCustomStyle(imageAt: file, title: title)
    }

    private nonisolated static func download(_ url: URL) async throws -> Data {
        let (bytes, response) = try await downloadSession.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ImportError.http(http.statusCode)
        }
        if let type = response.mimeType, ["text/", "video/", "audio/"].contains(where: type.hasPrefix) {
            throw ImportError.notImage(webPage: type.hasPrefix("text/"))
        }
        guard response.expectedContentLength <= maxDownloadBytes else { throw ImportError.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxDownloadBytes { throw ImportError.tooLarge }
        }
        return data
    }

    private static func webURL(_ text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text.contains("://") ? text : "https://" + text),
              ["http", "https"].contains(components.scheme?.lowercased()), components.host?.isEmpty == false else { return nil }
        components.scheme = "https"
        return components.url
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

    var captureFailureTitle: String {
        source == .camera ? "Camera unavailable" : "Video unavailable"
    }

    private static var currentCameraAuthorization: AVAuthorizationStatus {
        #if DEBUG
        if let simulated = DebugHooks.cameraAccess { return simulated }
        #endif
        return CameraCapture.authorizationStatus
    }

    private var needsCapture: Bool {
        isMainWindowVisible || (virtualCamera.sourceClientCount ?? 0) > 0 || keepsCameraOnForOBS
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
        case .starting, .running, .interrupted: return
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
                captureState = .failed("StyleCam cannot play \(url.lastPathComponent). " + Self.describe(error))
                return
            }
        }
        do {
            if source == .camera { try camera.selectDevice(id: preferences.cameraID) }
            try pipeline.start(source: frameSource)
            waitForFirstFrame()
        } catch {
            failCapture(Self.describe(error))
        }
    }

    private func stopCapture() {
        startTimeoutTask?.cancel()
        pipeline?.stop()
        preview.clear()
        captureState = .stopped
        stats = nil
    }

    private func failCapture(_ message: String) {
        startTimeoutTask?.cancel()
        pipeline?.stop()
        preview.clear()
        captureState = .failed(message)
        stats = nil
    }

    private func waitForFirstFrame() {
        awaitingFirstFrame.withLock { $0 = true }
        preview.resume()
        captureState = .starting
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, captureState == .starting else { return }
            failCapture(source == .camera ? "The camera did not start." : "The video did not start.")
        }
    }

    private func firstFrameArrived() {
        guard captureState == .starting else { return }
        startTimeoutTask?.cancel()
        captureState = .running
    }

    private func cameraSessionChanged(_ event: CameraSessionEvent) {
        switch (event, captureState) {
        case (.runtimeError(let error), .starting), (.runtimeError(let error), .running), (.runtimeError(let error), .interrupted):
            failCapture(error.map(Self.describe) ?? "The camera stopped working.")
        case (.interrupted, .starting), (.interrupted, .running):
            startTimeoutTask?.cancel()
            preview.clear()
            captureState = .interrupted
            stats = nil
        case (.interruptionEnded, .interrupted):
            waitForFirstFrame()
        default:
            break
        }
    }

    private func updatePreviewAttachment() {
        guard let pipeline, isPreviewAttached != isMainWindowVisible else { return }
        isPreviewAttached = isMainWindowVisible
        if isMainWindowVisible {
            preview.resume()
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
        case .starting, .running, .interrupted:
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
            failCapture(Self.describe(error))
        }
    }

    /// A sentence for the user. StyleKit errors describe themselves in lowercase for logs.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case CameraError.noDevice: return "No camera is connected."
        case CameraError.notAuthorized: return "StyleCam is not allowed to use the camera."
        case CameraError.cannotAddInput(let name): return "StyleCam cannot use \(name)."
        case StyleLibraryError.unreadableImage: return "That is not an image StyleCam can read."
        case let error as ImportError: return error.message
        case let error as URLError: return describe(error)
        default: break
        }
        if type(of: error) is NSObject.Type { return error.localizedDescription }
        let text = String(describing: error)
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    private static func describe(_ error: URLError) -> String {
        let host = error.failingURL?.host() ?? "the server"
        return switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "Your Mac is not connected to the internet."
        case .timedOut: "The download took too long."
        case .cannotFindHost, .dnsLookupFailed: "StyleCam cannot find \(host). Check the link."
        case .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection: "\(host) does not support secure (https) links."
        default: error.localizedDescription
        }
    }

    // MARK: - Setup

    private func startObserving() {
        guard let pipeline else { return }
        pipeline.addOutput(styleCamOutput)
        pipeline.addOutput(obsOutput)
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
        for output in [styleCamOutput, obsOutput] {
            Task { [weak self] in
                for await state in output.stateUpdates {
                    guard let self else { return }
                    guard output === virtualCameraOutput else { continue }
                    virtualCamera = state
                    updateCapture()
                }
            }
        }
        if source == .camera {
            cameras = camera.devices()
            observers = camera.observeDevices { [weak self] devices in self?.camerasChanged(devices) }
                + camera.observeSession { [weak self] event in self?.cameraSessionChanged(event) }
        }
        observers += [NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCameraAuthorization() }
        }]
        observers += [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == OBSVirtualCamera.appBundleID else { return }
                MainActor.assumeIsolated { self?.obsAppChanged() }
            }
        }
    }

    private func obsAppChanged() {
        guard preferences.virtualCameraTarget == .obs else { return }
        obsOutput.connect()
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
            setupError = "StyleCam could not load its styles. " + Self.describe(error)
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
        if preferences.virtualCameraTarget != old.virtualCameraTarget {
            (virtualCameraOutput === obsOutput ? styleCamOutput : obsOutput).disconnect()
            virtualCameraOutput.connect()
            virtualCamera = virtualCameraOutput.state
            updateCapture()
        }
        if preferences.cameraID != old.cameraID, source == .camera {
            switch captureState {
            case .failed: retryCapture()
            case .starting, .running, .interrupted: selectCamera()
            case .stopped: break
            }
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
        let network = network
        let style = preferences.isStylized ? styleVector : nil
        pipeline?.updateSettings { settings in
            settings.style = style
            settings.quality = preferences.quality.quality
            settings.network = network
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
