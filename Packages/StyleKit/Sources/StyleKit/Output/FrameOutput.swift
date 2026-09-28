import CoreMedia
import CoreVideo

/// Receives every output frame (NV12, 420v) in presentation order, on the pipeline's output queue.
public protocol FrameOutput: AnyObject, Sendable {
    func publish(_ pixelBuffer: CVPixelBuffer, time: CMTime)
}
