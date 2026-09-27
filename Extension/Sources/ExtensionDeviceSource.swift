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
    private let sourceStreaming = Atomic<Bool>(false)

    private let placeholder: PlaceholderFrame?
    private var sinkClient: CMIOExtensionClient?
    private var consumeTimer: DispatchSourceTimer?
    private var consumeInFlight = false
    private var placeholderTimer: DispatchSourceTimer?
    private var lastSinkFrameNanos: UInt64 = 0
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
        sourceStreaming.store(true, ordering: .relaxed)
        publishSourceClientCount()
        queue.async { self.startPlaceholderTimer() }
        logger.info("Source stream started")
    }

    func stopSource() {
        sourceStreaming.store(false, ordering: .relaxed)
        publishSourceClientCount()
        queue.async { self.stopPlaceholderTimer() }
        logger.info("Source stream stopped")
    }

    func startSink(client: CMIOExtensionClient) {
        nonisolated(unsafe) let client = client
        queue.async {
            self.sinkClient = client
            self.consumeInFlight = false
            self.startConsumeTimer()
        }
        logger.info("Sink stream started")
    }

    func stopSink() {
        queue.async {
            self.consumeTimer?.cancel()
            self.consumeTimer = nil
            self.sinkClient = nil
            self.consumeInFlight = false
            self.lastSinkFrameNanos = 0
        }
        logger.info("Sink stream stopped")
    }

    private func sourceClientCount() -> Int {
        guard sourceStreaming.load(ordering: .relaxed) else { return 0 }
        return max(1, sourceStream.stream.streamingClients.count)
    }

    private func sourceClientCountState() -> CMIOExtensionPropertyState<AnyObject> {
        CMIOExtensionPropertyState(value: String(sourceClientCount()) as NSString, attributes: .readOnlyPropertyAttribute)
    }

    private func publishSourceClientCount() {
        queue.async {
            self.device.notifyPropertiesChanged([self.sourceClientCountProperty: self.sourceClientCountState()])
        }
    }

    private func startConsumeTimer() {
        consumeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
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
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer), self.isPublishable(pixelBuffer) {
                    self.lastSinkFrameNanos = now
                    if self.sourceStreaming.load(ordering: .relaxed) {
                        self.sendToSource(pixelBuffer, hostTimeNanos: now)
                    }
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
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.defaultFrameDuration.seconds, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Self.hostTimeNanos()
            guard now &- self.lastSinkFrameNanos > Self.placeholderAfterNanos, let frame = placeholder.makeFrame() else { return }
            self.sendToSource(frame, hostTimeNanos: now)
        }
        placeholderTimer = timer
        timer.activate()
    }

    private func stopPlaceholderTimer() {
        // startSource sets the flag before queueing, so a restart queued behind this stop keeps the timer.
        guard !sourceStreaming.load(ordering: .relaxed) else { return }
        placeholderTimer?.cancel()
        placeholderTimer = nil
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

    private func sendToSource(_ pixelBuffer: CVPixelBuffer, hostTimeNanos: UInt64) {
        pixelBuffer.removeColorProfileAttachments()

        if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
            formatDescription = nil
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(
            duration: Self.defaultFrameDuration,
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
    }

    private static func hostTimeNanos() -> UInt64 {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(CMTimeConvertScale(now, timescale: 1_000_000_000, method: .default).value)
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
