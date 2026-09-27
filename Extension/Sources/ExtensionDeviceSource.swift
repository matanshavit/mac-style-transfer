import CoreMediaIO
import Foundation
import IOKit.audio
import os
import Synchronization

final class ExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    static let defaultFrameDuration = CMTime(value: 1, timescale: StyleCamVideo.frameRate)
    static let minFrameDuration = CMTime(value: 1, timescale: 60)
    static let maxFrameDuration = CMTime(value: 1, timescale: 1)
    private static let placeholderAfterNanos: UInt64 = 500_000_000

    static func clampedFrameDuration(_ duration: CMTime) -> CMTime {
        guard duration.isNumeric, duration.seconds > 0 else { return defaultFrameDuration }
        return CMTimeClampToRange(duration, range: CMTimeRange(start: minFrameDuration, end: maxFrameDuration))
    }

    private(set) var device: CMIOExtensionDevice!

    private var sourceStream: ExtensionStreamSource!
    private var sinkStream: ExtensionStreamSource!
    private var clientsObservation: NSKeyValueObservation?

    private let logger = Logger(subsystem: "com.matanshavit.StyleCam.Extension", category: "device")
    private let queue = DispatchQueue(label: "com.matanshavit.StyleCam.Extension.frames", qos: .userInteractive)
    private let sourceClientCountProperty = CMIOExtensionProperty(rawValue: StyleCamIDs.sourceClientCountProperty)
    private let sourceStartCount = Mutex(0)

    private let placeholder: PlaceholderFrame?
    private var sinkClient: CMIOExtensionClient?
    private var consumeTimer: DispatchSourceTimer?
    private var consumeInFlight = false
    private var placeholderTimer: DispatchSourceTimer?
    private var lastSinkFrameNanos: UInt64 = 0
    private var lastSourceFrameNanos: UInt64 = 0
    private var formatDescription: CMVideoFormatDescription?
    private var loggedRejectedFrame = false

    override init() {
        placeholder = PlaceholderFrame(width: Int(StyleCamVideo.width), height: Int(StyleCamVideo.height))
        super.init()
        if placeholder == nil {
            logger.error("Failed to render the placeholder frame")
        }

        device = CMIOExtensionDevice(
            localizedName: StyleCamIDs.deviceName,
            deviceID: UUID(uuidString: StyleCamIDs.deviceUID)!,
            legacyDeviceID: StyleCamIDs.deviceUID,
            source: self
        )

        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: StyleCamVideo.pixelFormat,
            width: StyleCamVideo.width,
            height: StyleCamVideo.height,
            extensions: nil,
            formatDescriptionOut: &description
        )
        let format = CMIOExtensionStreamFormat(
            formatDescription: description!,
            maxFrameDuration: Self.maxFrameDuration,
            minFrameDuration: Self.minFrameDuration,
            validFrameDurations: nil
        )

        sourceStream = ExtensionStreamSource(
            localizedName: "StyleCam Video",
            streamID: UUID(uuidString: StyleCamIDs.sourceStreamUID)!,
            direction: .source,
            format: format,
            deviceSource: self
        )
        sinkStream = ExtensionStreamSource(
            localizedName: "StyleCam Sink",
            streamID: UUID(uuidString: StyleCamIDs.sinkStreamUID)!,
            direction: .sink,
            format: format,
            deviceSource: self
        )
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            fatalError("Failed to add stream: \(error.localizedDescription)")
        }

        clientsObservation = sourceStream.stream.observe(\.streamingClients) { [weak self] _, _ in
            self?.publishSourceClientCount()
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, sourceClientCountProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = StyleCamIDs.model
        }
        if properties.contains(sourceClientCountProperty) {
            deviceProperties.setPropertyState(sourceClientCountState(), forProperty: sourceClientCountProperty)
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startSource() {
        let starts = sourceStartCount.withLock { count in
            count += 1
            return count
        }
        publishSourceClientCount()
        queue.async { self.updateTimers() }
        logger.info("Source stream started, \(starts) active")
    }

    func stopSource() {
        let starts = sourceStartCount.withLock { count in
            count = max(0, count - 1)
            return count
        }
        publishSourceClientCount()
        queue.async { self.updateTimers() }
        logger.info("Source stream stopped, \(starts) active")
    }

    func sourceFrameDurationChanged() {
        queue.async {
            self.placeholderTimer?.cancel()
            self.placeholderTimer = nil
            self.updateTimers()
        }
    }

    func startSink(client: CMIOExtensionClient) {
        nonisolated(unsafe) let client = client
        queue.async {
            self.sinkClient = client
            self.consumeInFlight = false
            self.updateTimers()
        }
        logger.info("Sink stream started by pid \(client.pid)")
    }

    func stopSink() {
        queue.async {
            self.sinkClient = nil
            self.consumeInFlight = false
            self.lastSinkFrameNanos = 0
            self.updateTimers()
        }
        logger.info("Sink stream stopped")
    }

    func disconnect(_ client: CMIOExtensionClient) {
        sinkStream.disconnect(client)
    }

    private var isSourceStreaming: Bool {
        sourceStartCount.withLock { $0 > 0 }
    }

    private func sourceClientCount() -> Int {
        let starts = sourceStartCount.withLock { $0 }
        guard starts > 0 else { return 0 }
        return max(starts, sourceStream.stream.streamingClients.count)
    }

    private func sourceClientCountState() -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: String(sourceClientCount()) as NSString, attributes: .readOnlyPropertyAttribute)
    }

    private func publishSourceClientCount() {
        queue.async {
            self.device.notifyPropertiesChanged([self.sourceClientCountProperty: self.sourceClientCountState()])
        }
    }

    private func updateTimers() {
        let sourceStreaming = isSourceStreaming
        if sourceStreaming {
            startPlaceholderTimer()
        } else {
            placeholderTimer?.cancel()
            placeholderTimer = nil
        }
        if sourceStreaming, sinkClient != nil {
            startConsumeTimer()
        } else {
            consumeTimer?.cancel()
            consumeTimer = nil
        }
    }

    private func startConsumeTimer() {
        guard consumeTimer == nil else { return }
        // The feeder gets one placeholder delay to deliver before the placeholder shows.
        lastSinkFrameNanos = Self.hostTimeNanos()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(StyleCamVideo.frameRate * 3), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.consumeSinkBuffer() }
        consumeTimer = timer
        timer.activate()
    }

    private func consumeSinkBuffer() {
        guard let client = sinkClient, !consumeInFlight else { return }
        consumeInFlight = true
        sinkStream.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, _, hasMore, _ in
            guard let self else { return }
            nonisolated(unsafe) let sampleBuffer = sampleBuffer
            self.queue.async {
                self.consumeInFlight = false
                guard let sampleBuffer else { return }
                let now = Self.hostTimeNanos()
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), self.isPublishable(pixelBuffer),
                   Self.isFresh(sampleBuffer, hostTimeNanos: now) {
                    self.lastSinkFrameNanos = now
                    self.forward(pixelBuffer, hostTimeNanos: now)
                }
                self.sinkStream.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: now)
                )
                if hasMore {
                    self.consumeSinkBuffer()
                }
            }
        }
    }

    private func startPlaceholderTimer() {
        guard placeholderTimer == nil, let placeholder else { return }
        let frameDuration = sourceStream.frameDuration
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: frameDuration.seconds, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.hostTimeNanos()
            guard now &- self.lastSinkFrameNanos > Self.placeholderAfterNanos, let frame = placeholder.makeFrame() else { return }
            self.sendToSource(frame, hostTimeNanos: now, frameDuration: frameDuration)
        }
        placeholderTimer = timer
        timer.activate()
    }

    private func forward(_ pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        let frameDuration = sourceStream.frameDuration
        guard isSourceStreaming, hostTimeNanos &- lastSourceFrameNanos >= Self.nanoseconds(frameDuration) / 10 * 9 else { return }
        sendToSource(pixelBuffer, hostTimeNanos: hostTimeNanos, frameDuration: frameDuration)
    }

    private static func isFresh(_ sampleBuffer: CMSampleBuffer, hostTimeNanos: UInt64) -> Bool {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else { return true }
        let age = Int64(bitPattern: hostTimeNanos) &- Int64(bitPattern: nanoseconds(presentationTime))
        return age <= Int64(placeholderAfterNanos)
    }

    private func isPublishable(_ pixelBuffer: CVPixelBuffer) -> Bool {
        let matches = CVPixelBufferGetWidth(pixelBuffer) == Int(StyleCamVideo.width)
            && CVPixelBufferGetHeight(pixelBuffer) == Int(StyleCamVideo.height)
            && CVPixelBufferGetPixelFormatType(pixelBuffer) == StyleCamVideo.pixelFormat
        if !matches, !loggedRejectedFrame {
            logger.error("Dropping sink frames that are not \(StyleCamVideo.width)x\(StyleCamVideo.height) 420v")
        }
        loggedRejectedFrame = !matches
        return matches
    }

    private func sendToSource(_ pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64, frameDuration: CMTime) {
        pixelBuffer.removeColorProfileAttachments()

        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMTime(value: CMTimeValue(hostTimeNanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            logger.error("Failed to create a source sample buffer: \(status)")
            return
        }
        sourceStream.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: hostTimeNanos)
        lastSourceFrameNanos = hostTimeNanos
    }

    private static func hostTimeNanos() -> UInt64 {
        nanoseconds(CMClockGetTime(CMClockGetHostTimeClock()))
    }

    private static func nanoseconds(_ time: CMTime) -> UInt64 {
        UInt64(bitPattern: CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value)
    }
}

extension CVBuffer {
    /// Clients rebuild a CGColorSpace from these on every frame. The YCbCr matrix alone is enough to decode 420v.
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
