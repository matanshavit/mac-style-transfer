import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// Pushes video frames into the sink stream of a CMIO virtual camera.
///
/// `send(_:)` is safe to call from any thread, including a realtime capture queue. Connection
/// management runs on an internal queue and follows the device as it appears and disappears.
public final class VirtualCameraOutput: @unchecked Sendable {
    public enum Status: Sendable, Equatable {
        case disconnected
        case notFound
        /// Found, but another app feeds it (see `yieldsWhile`).
        case busy
        case connected(deviceName: String)
        case error(String)
    }

    public struct State: Sendable, Equatable {
        public var status: Status
        /// Clients streaming from the camera, when the device publishes a client count property.
        public var sourceClientCount: Int?
    }

    public let deviceUID: String?
    public let fallbackDeviceName: String?
    /// Latest state first, then every change. Supports a single consumer.
    public let stateUpdates: AsyncStream<State>

    private static let stallTimeout = Duration.seconds(2)

    private let clientCountSelector: CMIOObjectPropertySelector?
    private let otherFeederIsActive: (@Sendable () -> Bool)?
    private let stateContinuation: AsyncStream<State>.Continuation
    private let queue = DispatchQueue(label: "StyleKit.VirtualCameraOutput", qos: .userInitiated)
    private let lock = OSAllocatedUnfairLock()
    private let frameLock = OSAllocatedUnfairLock()

    private var currentState = State(status: .disconnected)
    private var sink: Sink?
    private var wantsSink = true
    private var fullSince: ContinuousClock.Instant?
    private var formatDescription: CMVideoFormatDescription?

    private var wantsConnection = false
    private var devicesListener: CMIOObjectPropertyListenerBlock?
    private var clientCountTimer: DispatchSourceTimer?
    private var retryTimer: DispatchSourceTimer?

    /// - Parameters:
    ///   - clientCountSelector: four-character selector of a device property holding the source client
    ///     count as a decimal string, such as `StyleCamIDs.sourceClientCountSelector`.
    ///   - yieldsWhile: for a sink that another app feeds too, like OBS's. There the last app to start the
    ///     sink gets it, and any app that stops it stops it for all. While this returns true, the output
    ///     leaves the sink to the other app and reports `.busy`. Otherwise a sink whose queue stays full for
    ///     2 s while frames are sent was taken over or stopped by another feeder, and is restarted.
    public init(deviceUID: String?, fallbackDeviceName: String? = nil, clientCountSelector: String? = nil,
                yieldsWhile otherFeederIsActive: (@Sendable () -> Bool)? = nil) {
        self.deviceUID = deviceUID
        self.fallbackDeviceName = fallbackDeviceName
        self.clientCountSelector = clientCountSelector.flatMap(FourCC.code)
        self.otherFeederIsActive = otherFeederIsActive
        (stateUpdates, stateContinuation) = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuation.yield(currentState)
    }

    deinit {
        removeDevicesListener()
        clientCountTimer?.cancel()
        retryTimer?.cancel()
        sink?.stop()
        stateContinuation.finish()
    }

    public var state: State {
        lock.withLockUnchecked { currentState }
    }

    /// Whether the sink stream runs while connected. Off, the output still follows the device and
    /// reports it as connected (or the last start error), but leaves the sink stopped and drops frames.
    public var holdsSink: Bool {
        get { lock.withLockUnchecked { wantsSink } }
        set {
            let changed = lock.withLockUnchecked {
                defer { wantsSink = newValue }
                return wantsSink != newValue
            }
            if changed { queue.async { [weak self] in self?.reconnect() } }
        }
    }

    /// Connects now and keeps reconnecting as the device list changes, and every few seconds after
    /// a failed start, until `disconnect()`. Calling it again checks again now.
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
            stopRetrying()
            teardown()
            update { $0 = State(status: .disconnected) }
        }
    }

    /// Enqueues one frame and returns whether the sink accepted it.
    ///
    /// Drops the frame when the sink queue is full. Frames are sent as they are, whatever format the
    /// sink declares. ICC profile, color space, primaries, transfer function and gamma attachments are
    /// removed from the buffer that is sent.
    @discardableResult
    public func send(_ pixelBuffer: CVPixelBuffer) -> Bool {
        guard let target = lock.withLockUnchecked({ sink }) else { return false }
        guard CMSimpleQueueGetCount(target.queue) < CMSimpleQueueGetCapacity(target.queue) else {
            if otherFeederIsActive != nil { queueWasFull(target) }
            return false
        }
        let prepared: CMSampleBuffer? = frameLock.withLockUnchecked {
            pixelBuffer.removeColorProfileAttachments()
            return sampleBuffer(for: pixelBuffer)
        }
        guard let prepared else { return false }

        return lock.withLockUnchecked {
            guard sink?.queue === target.queue else { return false }
            let element = Unmanaged.passRetained(prepared).toOpaque()
            guard CMSimpleQueueEnqueue(target.queue, element: element) == noErr else {
                Unmanaged<CMSampleBuffer>.fromOpaque(element).release()
                return false
            }
            fullSince = nil
            return true
        }
    }

    private func queueWasFull(_ target: Sink) {
        let now = ContinuousClock.now
        let stalled = lock.withLockUnchecked {
            guard sink?.queue === target.queue else { return false }
            guard let since = fullSince else {
                fullSince = now
                return false
            }
            guard now - since >= Self.stallTimeout else { return false }
            fullSince = nil
            return true
        }
        guard stalled else { return }
        let stalledQueue = ObjectIdentifier(target.queue)
        queue.async { [weak self] in
            guard let self, lock.withLockUnchecked({ self.sink.map { ObjectIdentifier($0.queue) } == stalledQueue }) else { return }
            teardown()
            reconnect()
        }
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
        guard let device = deviceUID.flatMap(CMIODeviceDirectory.device(uid:)) ?? fallbackDeviceName.flatMap(CMIODeviceDirectory.device(named:)) else {
            release { $0 = State(status: .notFound) }
            return
        }
        if otherFeederIsActive?() == true {
            release { $0 = State(status: .busy) }
            return
        }
        guard lock.withLockUnchecked({ wantsSink }) else {
            release { state in
                if case .error = state.status { return }
                state = State(status: .connected(deviceName: device.name))
            }
            return
        }
        if lock.withLockUnchecked({ sink?.deviceID == device.id }) { return }

        teardown()
        guard let stream = device.sinkStream else {
            fail("\(device.name) has no sink stream")
            return
        }
        switch Sink.start(deviceID: device.id, stream: stream) {
        case .success(let started):
            stopRetrying()
            lock.withLockUnchecked { sink = started }
            let count = readClientCount(device.id)
            update { $0 = State(status: .connected(deviceName: device.name), sourceClientCount: count) }
            startClientCountTimer(deviceID: device.id)
        case .failure(let error):
            fail(error.message)
        }
    }

    private func release(_ change: (inout State) -> Void) {
        stopRetrying()
        teardown()
        update(change)
    }

    private func fail(_ message: String) {
        update { $0 = State(status: .error(message)) }
        guard retryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.reconnect() }
        retryTimer = timer
        timer.activate()
    }

    private func stopRetrying() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    private func teardown() {
        clientCountTimer?.cancel()
        clientCountTimer = nil
        let stopped = lock.withLockUnchecked {
            defer {
                sink = nil
                fullSince = nil
            }
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

extension VirtualCameraOutput: FrameOutput {
    public func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        send(pixelBuffer)
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
        return .success(Sink(deviceID: deviceID, streamID: stream.id, queue: queue))
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
