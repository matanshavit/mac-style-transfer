@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization

public struct CameraDevice: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let modelID: String
    public let manufacturer: String
    public let isExternal: Bool

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
        modelID = device.modelID
        manufacturer = device.manufacturer
        isExternal = device.deviceType != .builtInWideAngleCamera
    }
}

public enum CameraError: Error, CustomStringConvertible {
    case notAuthorized
    case noDevice
    case cannotAddInput(String)
    case cannotAddOutput

    public var description: String {
        switch self {
        case .notAuthorized: "camera access is not authorized"
        case .noDevice: "no camera is available"
        case .cannotAddInput(let name): "cannot use camera \(name)"
        case .cannotAddOutput: "cannot add the video output"
        }
    }
}

/// Captures 1280x720 BGRA at 30 fps from a real camera. Devices whose uniqueID is in `excludedDeviceUIDs` are never
/// listed or opened, so the app's own virtual camera cannot feed itself.
public final class CameraCapture: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static let width = 1280
    public static let height = 720
    public static let frameRate = 30

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    public let excludedDeviceUIDs: Set<String>

    private struct State {
        var handler: FrameHandler?
        var clock: CMClock?
        var selectedDeviceID: String?
        var activeDevice: CameraDevice?
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "StyleKit.CameraCapture.session")
    private let outputQueue = DispatchQueue(label: "StyleKit.CameraCapture.output", qos: .userInteractive)
    private let state = Mutex(State())

    public init(excludedDeviceUIDs: Set<String> = []) {
        self.excludedDeviceUIDs = excludedDeviceUIDs
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
    }

    public func devices() -> [CameraDevice] {
        captureDevices().map(CameraDevice.init)
    }

    public var activeDevice: CameraDevice? { state.withLock { $0.activeDevice } }

    /// Picks the camera to use; nil means the system preferred camera. Applies immediately when running.
    public func selectDevice(id: String?) throws {
        let running = state.withLock { state -> Bool in
            state.selectedDeviceID = id
            return state.handler != nil
        }
        guard running else { return }
        try sessionQueue.sync { try configure() }
    }

    /// Calls `onChange` on the main queue with the current device list whenever a camera connects or disconnects.
    public func observeDevices(_ onChange: @escaping @MainActor @Sendable ([CameraDevice]) -> Void) -> [any NSObjectProtocol] {
        [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let devices = self?.devices() else { return }
                MainActor.assumeIsolated { onChange(devices) }
            }
        }
    }

    /// Configures the session synchronously so errors surface here; the session starts running asynchronously.
    public func start(handler: @escaping FrameHandler) throws {
        guard Self.authorizationStatus == .authorized else { throw CameraError.notAuthorized }
        try sessionQueue.sync { try configure() }
        state.withLock { $0.handler = handler }
        sessionQueue.async { [self] in session.startRunning() }
    }

    public func stop() {
        state.withLock { $0.handler = nil }
        sessionQueue.async { [self] in session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let (handler, hostTime) = state.withLock { state -> (FrameHandler?, CMTime) in
            guard let clock = state.clock else { return (state.handler, presentationTime) }
            return (state.handler, CMSyncConvertTime(presentationTime, from: clock, to: CMClockGetHostTimeClock()))
        }
        handler?(VideoFrame(pixelBuffer: pixelBuffer, presentationTime: presentationTime, hostTime: hostTime))
    }

    private func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.filter { !excludedDeviceUIDs.contains($0.uniqueID) && $0.isConnected }
    }

    private func chooseDevice() -> AVCaptureDevice? {
        let devices = captureDevices()
        if let id = state.withLock({ $0.selectedDeviceID }), let match = devices.first(where: { $0.uniqueID == id }) {
            return match
        }
        if let preferred = AVCaptureDevice.systemPreferredCamera, devices.contains(preferred) {
            return preferred
        }
        return devices.first { $0.deviceType == .builtInWideAngleCamera } ?? devices.first
    }

    private func configure() throws {
        guard let device = chooseDevice() else { throw CameraError.noDevice }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput(device.localizedName) }
        session.addInput(input)
        if session.outputs.isEmpty {
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }

        let format = bestFormat(for: device)
        var settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let format {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(Self.frameRate))
            if format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            if Int(dimensions.width) * Self.height == Int(dimensions.height) * Self.width {
                settings[kCVPixelBufferWidthKey as String] = Self.width
                settings[kCVPixelBufferHeightKey as String] = Self.height
            }
        }
        output.videoSettings = settings
        let clock = session.synchronizationClock
        state.withLock { state in
            state.clock = clock
            state.activeDevice = CameraDevice(device)
        }
    }

    /// The smallest 30 fps format that covers 1280x720, preferring 16:9.
    private func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let target = Double(Self.frameRate)
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width >= Self.width && d.height >= Self.height
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target && target <= $0.maxFrameRate }
        }
        return candidates.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            let wideA = Int(da.width) * 9 == Int(da.height) * 16, wideB = Int(db.width) * 9 == Int(db.height) * 16
            if wideA != wideB { return wideA }
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }
    }
}
