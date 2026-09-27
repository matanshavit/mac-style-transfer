import CoreMediaIO
import Foundation
import os

final class ExtensionStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let formats: [CMIOExtensionStreamFormat]

    private unowned let deviceSource: ExtensionDeviceSource
    private let direction: CMIOExtensionStream.Direction
    private let frameDuration: OSAllocatedUnfairLock<CMTime>
    private let authorizedClient = OSAllocatedUnfairLock<CMIOExtensionClient?>(uncheckedState: nil)

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
        self.frameDuration = OSAllocatedUnfairLock(initialState: ExtensionDeviceSource.defaultFrameDuration)
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: direction,
            clockType: .hostTime,
            source: self
        )
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
            streamProperties.frameDuration = frameDuration.withLock { $0 }
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
        if let requested = streamProperties.frameDuration {
            frameDuration.withLock { $0 = ExtensionDeviceSource.clampedFrameDuration(requested) }
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if direction == .sink {
            authorizedClient.withLockUnchecked { $0 = client }
        }
        return true
    }

    func startStream() throws {
        switch direction {
        case .sink:
            guard let client = authorizedClient.withLockUnchecked({ $0 }) else {
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
            authorizedClient.withLockUnchecked { $0 = nil }
            deviceSource.stopSink()
        default:
            deviceSource.stopSource()
        }
    }
}
