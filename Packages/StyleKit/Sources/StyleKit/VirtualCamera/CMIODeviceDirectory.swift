import CoreMedia
import CoreMediaIO

public enum CMIODeviceDirectory {
    public struct Device: Sendable, Hashable, Identifiable {
        public let id: CMIOObjectID
        public let name: String
        public let uid: String
        public let streams: [Stream]

        public var sinkStream: Stream? { streams.first { $0.direction == .sink } }
    }

    public struct Stream: Sendable, Hashable, Identifiable {
        public let id: CMIOStreamID
        public let name: String?
        public let direction: Direction?
        public let format: VideoFormat?
    }

    public enum Direction: Sendable, Hashable {
        /// Delivers video to clients, like a physical camera. `kCMIOStreamPropertyDirection` is 1 (input).
        case source
        /// Accepts video from clients through its buffer queue. `kCMIOStreamPropertyDirection` is 0 (output).
        case sink
    }

    public struct VideoFormat: Sendable, Hashable {
        public let pixelFormat: OSType
        public let width: Int32
        public let height: Int32

        public var pixelFormatName: String { FourCC.string(pixelFormat) }

        public init(pixelFormat: OSType, width: Int32, height: Int32) {
            self.pixelFormat = pixelFormat
            self.width = width
            self.height = height
        }

        public init(_ pixelBuffer: CVPixelBuffer) {
            self.init(
                pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
                width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
                height: Int32(CVPixelBufferGetHeight(pixelBuffer))
            )
        }
    }

    public static func devices() -> [Device] {
        CMIOProperty.objectIDs(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).compactMap(device(id:))
    }

    public static func device(uid: String) -> Device? {
        devices().first { $0.uid == uid }
    }

    public static func device(named name: String) -> Device? {
        devices().first { $0.name == name }
    }

    static func device(id: CMIOObjectID) -> Device? {
        guard let uid = CMIOProperty.string(id, kCMIODevicePropertyDeviceUID) else { return nil }
        return Device(
            id: id,
            name: CMIOProperty.string(id, kCMIOObjectPropertyName) ?? uid,
            uid: uid,
            streams: CMIOProperty.objectIDs(id, kCMIODevicePropertyStreams).map(stream(id:))
        )
    }

    private static func stream(id: CMIOStreamID) -> Stream {
        let direction: Direction? = switch CMIOProperty.uint32(id, kCMIOStreamPropertyDirection) {
        case 0: .sink
        case 1: .source
        default: nil
        }
        let format = CMIOProperty.formatDescription(id).map { description in
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            return VideoFormat(pixelFormat: CMFormatDescriptionGetMediaSubType(description), width: dimensions.width, height: dimensions.height)
        }
        return Stream(id: id, name: CMIOProperty.string(id, kCMIOObjectPropertyName), direction: direction, format: format)
    }
}
