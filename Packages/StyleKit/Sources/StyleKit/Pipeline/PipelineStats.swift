import CoreMedia
import Synchronization

public struct FrameTimings: Sendable {
    /// GPU time of the downscale pass.
    public var downscaleMilliseconds: Double = 0
    /// Wall time of the transformer prediction.
    public var inferenceMilliseconds: Double = 0
    /// GPU time of smoothing, upsampling, compositing and NV12 conversion.
    public var postMilliseconds: Double = 0
    /// From admission into the pipeline to output.
    public var totalMilliseconds: Double = 0
    /// From capture (the frame's host time) to output.
    public var latencyMilliseconds: Double = 0
    public var device: ComputeDevice?
}

public struct PipelineStats: Sendable {
    public var captureFPS: Double
    public var outputFPS: Double
    public var inferenceMillisecondsP50: Double
    public var latencyMillisecondsP50: Double
    /// Frames dropped since the previous stats update.
    public var droppedFrames: Int
    public var totalDroppedFrames: Int
    /// For example "960x540 gpu", or nil while bypassing.
    public var engine: String?
    public var lastError: String?
}

final class StatsCollector: Sendable {
    private struct Window {
        var start = HostClock.now()
        var captured = 0
        var output = 0
        var dropped = 0
        var totalDropped = 0
        var inference: [Double] = []
        var latency: [Double] = []
    }

    private let window = Mutex(Window())

    func recordCapture() {
        window.withLock { $0.captured += 1 }
    }

    func recordDrop() {
        window.withLock {
            $0.dropped += 1
            $0.totalDropped += 1
        }
    }

    func recordOutput(_ timings: FrameTimings) {
        window.withLock {
            $0.output += 1
            if timings.device != nil { $0.inference.append(timings.inferenceMilliseconds) }
            $0.latency.append(timings.latencyMilliseconds)
        }
    }

    func snapshot(engine: String?, lastError: String?) -> PipelineStats {
        window.withLock { window in
            let now = HostClock.now()
            let seconds = max((now - window.start).seconds, 1e-3)
            let stats = PipelineStats(
                captureFPS: Double(window.captured) / seconds, outputFPS: Double(window.output) / seconds,
                inferenceMillisecondsP50: median(window.inference), latencyMillisecondsP50: median(window.latency),
                droppedFrames: window.dropped, totalDroppedFrames: window.totalDropped, engine: engine, lastError: lastError)
            window = Window(start: now, totalDropped: window.totalDropped)
            return stats
        }
    }
}

func median(_ values: [Double]) -> Double {
    percentile(values, 0.5)
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int((fraction * Double(sorted.count - 1)).rounded()))]
}
