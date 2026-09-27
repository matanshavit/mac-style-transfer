import CoreMediaIO
import Foundation
import os

final class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private struct SinkClients {
        var authorized: CMIOExtensionClient?
        var active: CMIOExtensionClient?
    }

    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]

    private unowned let deviceSource: ExtensionDeviceSource
    private let direction: CMIOExtensionStream.Direction
    private let storedFrameDuration: OSAllocatedUnfairLock<CMTime>
    private let sinkClients = OSAllocatedUnfairLock(uncheckedState: SinkClients())
    private let logger = Logger(subsystem: "com.matanshavit.StyleCam.Extension", category: "stream")

    init(
        localizedName: String,
        streamID: UUID,
        direction: CMIOExtensionStream.Direction,
        format: CMIOExtensionStreamFormat,
        deviceSource: ExtensionDeviceSource
    ) {
        self.formats = [format]
        self.direction = direction
        self.deviceSource = deviceSource
        self.storedFrameDuration = OSAllocatedUnfairLock(initialState: ExtensionDeviceSource.defaultFrameDuration)
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: direction,
            clockType: .hostTime,
            source: self
        )
    }

    var frameDuration: CMTime {
        storedFrameDuration.withLock { $0 }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        let properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration, .streamMaxFrameDuration]
        guard direction == .sink else { return properties }
        return properties.union([
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData,
        ])
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamMaxFrameDuration) {
            streamProperties.maxFrameDuration = ExtensionDeviceSource.maxFrameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 1
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            streamProperties.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        guard let requested = streamProperties.frameDuration else { return }
        let duration = ExtensionDeviceSource.clampedFrameDuration(requested)
        let changed = storedFrameDuration.withLock { stored in
            defer { stored = duration }
            return CMTimeCompare(stored, duration) != 0
        }
        guard changed else { return }
        stream.notifyPropertiesChanged([
            .streamFrameDuration: CMIOExtensionPropertyState(value: CMTimeCopyAsDictionary(duration, allocator: kCFAllocatorDefault)),
        ])
        if direction == .source {
            deviceSource.sourceFrameDurationChanged()
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard direction == .sink else { return true }
        let authorized = sinkClients.withLockUnchecked { clients in
            if let active = clients.active, active.clientID != client.clientID { return false }
            clients.authorized = client
            return true
        }
        if !authorized {
            logger.error("Rejected sink client pid \(client.pid) while another feeder is active")
        }
        return authorized
    }

    func startStream() throws {
        switch direction {
        case .sink:
            let client = sinkClients.withLockUnchecked { clients in
                clients.active = clients.authorized
                return clients.active
            }
            guard let client else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Sink stream started without a client"])
            }
            deviceSource.startSink(client: client)
        default:
            deviceSource.startSource()
        }
    }

    func stopStream() throws {
        switch direction {
        case .sink:
            sinkClients.withLockUnchecked { $0.active = nil }
            deviceSource.stopSink()
        default:
            deviceSource.stopSource()
        }
    }

    func disconnect(_ client: CMIOExtensionClient) {
        let wasActive = sinkClients.withLockUnchecked { clients in
            if clients.authorized?.clientID == client.clientID {
                clients.authorized = nil
            }
            guard clients.active?.clientID == client.clientID else { return false }
            clients.active = nil
            return true
        }
        if wasActive {
            deviceSource.stopSink()
        }
    }
}
