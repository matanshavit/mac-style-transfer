import CoreMedia
import CoreVideo

/// A captured BGRA frame. `hostTime` is the capture moment on the host clock and is what latency is measured from.
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime
    public let hostTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime, hostTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
        self.hostTime = hostTime
    }
}

public typealias FrameHandler = @Sendable (VideoFrame) -> Void

public protocol FrameSource: AnyObject, Sendable {
    func start(handler: @escaping FrameHandler) throws
    func stop()
}

enum HostClock {
    static func now() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    static func milliseconds(since start: CMTime) -> Double {
        (now() - start).seconds * 1000
    }
}
