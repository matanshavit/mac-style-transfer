import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os
import VideoToolbox

/// Pushes video frames into the sink stream of a CMIO virtual camera.
///
/// `send(_:)` is safe to call from any thread, including a realtime capture queue. Connection
/// management runs on an internal queue and follows the device as it appears and disappears.
public final class VirtualCameraOutput: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case disconnected
        case notFound
        case connected(deviceName: String)
        case error(String)
    }

    public struct State: Sendable, Equatable {
        public var status: Status
        /// Clients streaming from the camera, when the device publishes a client count property.
        public var sourceClientCount: Int?
    }

    public let deviceUID: String
    public let fallbackDeviceName: String?
    /// Latest state first, then every change. Supports a single consumer.
    public let stateUpdates: AsyncStream<State>

    private let clientCountSelector: CMIOObjectPropertySelector?
    private let stateContinuation: AsyncStream<State>.Continuation
    private let queue = DispatchQueue(label: "StyleKit.VirtualCameraOutput", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()

    private var currentState = State(status: .disconnected)
    private var sink: Sink?
    private var converter: Converter?
    private var formatDescription: CMVideoFormatDescription?

    private var wantsConnection = false
    private var devicesListener: CMIOObjectPropertyListenerBlock?
    private var clientCountTimer: DispatchSourceTimer?

    /// - Parameter clientCountSelector: four-character selector of a device property holding the
    ///   source client count as a decimal string, such as `StyleCamIDs.sourceClientCountSelector`.
    public init(deviceUID: String, fallbackDeviceName: String? = nil, clientCountSelector: String? = nil) {
        self.deviceUID = deviceUID
        self.fallbackDeviceName = fallbackDeviceName
        self.clientCountSelector = clientCountSelector.flatMap(FourCC.code)
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuation.yield(currentState)
    }

    deinit {
        removeDevicesListener()
        clientCountTimer?.cancel()
        sink?.stop()
        stateContinuation.finish()
    }

    public var state: State {
        lock.withLockUnchecked { currentState }
    }

    /// Connects now and keeps reconnecting as the device list changes, until `disconnect()`.
    @discardableResult
    public func connect() -> Status {
        dispatchPrecondition(condition: .notOnQueue(queue))
        return queue.sync {
            wantsConnection = true
            addDevicesListener()
            reconnect()
            return state.status
        }
    }

    public func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(queue))
        queue.sync {
            wantsConnection = false
            removeDevicesListener()
            teardown()
            update { $0 = State(status: .disconnected) }
        }
    }

    /// Enqueues one frame and returns whether the sink accepted it.
    ///
    /// Drops the frame when the sink queue is full. Frames that do not match the sink's format are
    /// converted. ICC profile, color space, primaries, transfer function and gamma attachments are
    /// removed from the buffer that is sent.
    @discardableResult
    public func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        lock.withLockUnchecked {
            guard let sink, CMSimpleQueueGetCount(sink.queue) < CMSimpleQueueGetCapacity(sink.queue) else { return false }
            guard let frame = frame(for: pixelBuffer, format: sink.format) else { return false }
            frame.removeColorProfileAttachments()
            guard let sampleBuffer = sampleBuffer(for: frame) else { return false }

            let element = Unmanaged.passRetained(sampleBuffer).toOpaque()
            guard CMSimpleQueueEnqueue(sink.queue, element: element) == noErr else {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
                return false
            }
            return true
        }
    }

    private func frame(for pixelBuffer: CVPixelBuffer, format: CMIODeviceDirectory.VideoFormat?) -> CVPixelBuffer? {
        guard let format, format != CMIODeviceDirectory.VideoFormat(pixelBuffer) else { return pixelBuffer }
        if converter?.format != format {
            converter = Converter(format: format)
        }
        return converter?.convert(pixelBuffer)
    }

    private func sampleBuffer(for pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    private func reconnect() {
        guard wantsConnection else { return }
        guard let device = CMIODeviceDirectory.device(uid: deviceUID) ?? fallbackDeviceName.flatMap(CMIODeviceDirectory.device(named:)) else {
            teardown()
            update { $0 = State(status: .notFound) }
            return
        }
        if lock.withLockUnchecked({ sink?.deviceID == device.id }) { return }

        teardown()
        guard let stream = device.sinkStream else {
            update { $0 = State(status: .error("\(device.name) has no sink stream")) }
            return
        }
        switch Sink.start(deviceID: device.id, stream: stream) {
        case .success(let started):
            lock.withLockUnchecked { sink = started }
            let count = readClientCount(device.id)
            update { $0 = State(status: .connected(deviceName: device.name), sourceClientCount: count) }
            startClientCountTimer(deviceID: device.id)
        case .failure(let error):
            update { $0 = State(status: .error(error.message)) }
        }
    }

    private func teardown() {
        clientCountTimer?.cancel()
        clientCountTimer = nil
        let stopped = lock.withLockUnchecked {
            defer { sink = nil }
            return sink
        }
        stopped?.stop()
    }

    private func addDevicesListener() {
        guard devicesListener == nil else { return }
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.reconnect() }
        var address = CMIOProperty.address(kCMIOHardwarePropertyDevices)
        guard CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, listener) == noErr else { return }
        devicesListener = listener
    }

    private func removeDevicesListener() {
        guard let devicesListener else { return }
        var address = CMIOProperty.address(kCMIOHardwarePropertyDevices)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, devicesListener)
        self.devicesListener = nil
    }

    private func startClientCountTimer(deviceID: CMIOObjectID) {
        guard clientCountSelector != nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let count = self.readClientCount(deviceID)
            self.update { $0.sourceClientCount = count }
        }
        clientCountTimer = timer
        timer.activate()
    }

    private func readClientCount(_ deviceID: CMIOObjectID) -> Int? {
        clientCountSelector.flatMap { CMIOProperty.string(deviceID, $0) }.flatMap { Int($0) }
    }

    private func update(_ change: (inout State) -> Void) {
        let changed: State? = lock.withLockUnchecked {
            var next = currentState
            change(&next)
            guard next != currentState else { return nil }
            currentState = next
            return next
        }
        if let changed {
            stateContinuation.yield(changed)
        }
    }
}

extension VirtualCameraOutput.State {
    init(status: VirtualCameraOutput.Status) {
        self.init(status: status, sourceClientCount: nil)
    }
}

private struct Sink {
    struct StartError: Error {
        let message: String
    }

    let deviceID: CMIOObjectID
    let streamID: CMIOStreamID
    let queue: CMSimpleQueue
    let format: CMIODeviceDirectory.VideoFormat?

    static func start(deviceID: CMIOObjectID, stream: CMIODeviceDirectory.Stream) -> Result<Sink, StartError> {
        var queue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(stream.id, { _, _, _ in }, nil, &queue)
        guard copyStatus == noErr, let queue = queue?.takeRetainedValue() else {
            return .failure(StartError(message: "CMIOStreamCopyBufferQueue failed (\(copyStatus))"))
        }
        let startStatus = CMIODeviceStartStream(deviceID, stream.id)
        guard startStatus == noErr else {
            unregisterQueueCallback(stream.id)
            return .failure(StartError(message: "CMIODeviceStartStream failed (\(startStatus))"))
        }
        return .success(Sink(deviceID: deviceID, streamID: stream.id, queue: queue, format: stream.format))
    }

    func stop() {
        CMIODeviceStopStream(deviceID, streamID)
        Self.unregisterQueueCallback(streamID)
    }

    private static func unregisterQueueCallback(_ streamID: CMIOStreamID) {
        var queue: Unmanaged<CMSimpleQueue>?
        if CMIOStreamCopyBufferQueue(streamID, nil, nil, &queue) == noErr {
            queue?.release()
        }
    }
}

private final class Converter {
    let format: CMIODeviceDirectory.VideoFormat
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private let allocationAttributes = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary

    init?(format: CMIODeviceDirectory.VideoFormat) {
        let attributes = [
            kCVPixelBufferWidthKey: Int(format.width),
            kCVPixelBufferHeightKey: Int(format.height),
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        var session: VTPixelTransferSession?
        var pool: CVPixelBufferPool?
        guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session) == noErr, let session,
              CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes, &pool) == kCVReturnSuccess, let pool
        else { return nil }
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Trim)
        self.format = format
        self.session = session
        self.pool = pool
    }

    deinit {
        VTPixelTransferSessionInvalidate(session)
    }

    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, allocationAttributes, &destination) == kCVReturnSuccess,
              let destination,
              VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr
        else { return nil }
        return destination
    }
}

extension CVBuffer {
    /// Clients rebuild a CGColorSpace from these on every frame. The YCbCr matrix alone is enough to decode YCbCr.
    func removeColorProfileAttachments() {
        for key in [
            kCVImageBufferICCProfileKey,
            kCVImageBufferCGColorSpaceKey,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferGammaLevelKey,
        ] {
            CVBufferRemoveAttachment(self, key)
        }
    }
}
