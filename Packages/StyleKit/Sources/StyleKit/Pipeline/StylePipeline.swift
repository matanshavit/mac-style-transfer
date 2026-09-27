import CoreMedia
import CoreVideo
import Foundation
import Metal
import Synchronization

public struct ProcessedFrame: @unchecked Sendable {
    /// NV12 video range, BT.601, at the pipeline's output size.
    public let output: CVPixelBuffer
    public let source: VideoFrame
    public let stylized: Bool
    public let timings: FrameTimings
}

/// Camera frame -> downscale -> style engine -> temporal smoothing -> upsample and composite -> NV12 -> outputs.
///
/// Settings can change from any thread and apply from the next admitted frame. At most one frame is in flight for a
/// single-device engine and two for dual, so latency never queues up: in `.dropFrames` mode a frame that arrives
/// while the pipeline is full is dropped, in `.waitForSlot` mode the source's thread blocks (for offline runs).
public final class StylePipeline: @unchecked Sendable {
    public enum Backpressure: Sendable {
        case dropFrames
        case waitForSlot
    }

    public static let contentVectorInterval = CMTime(value: 1, timescale: 2)

    public let modelStore: ModelStore
    public let outputWidth: Int
    public let outputHeight: Int
    public let backpressure: Backpressure

    private struct Shared: Sendable {
        var settings: PipelineSettings
        var outputs: [any FrameOutput] = []
        var onFrame: (@Sendable (ProcessedFrame) -> Void)?
        var onStats: (@Sendable (PipelineStats) -> Void)?
        var statsContinuations: [UUID: AsyncStream<PipelineStats>.Continuation] = [:]
        var source: (any FrameSource)?
        var engine: String?
        var lastError: String?
    }

    private enum PredictorState {
        case idle
        case loading
        case ready(StylePredictor)
        case failed
    }

    private final class Job: @unchecked Sendable {
        let frame: VideoFrame
        let settings: PipelineSettings
        let admitted = HostClock.now()
        var style: StyleVector?
        var resetHistory = false
        var input: CVPixelBuffer?
        var predictorInput: CVPixelBuffer?
        /// Held until the post pass completes so the engine's pool cannot reuse it while the GPU reads it.
        var stylized: CVPixelBuffer?
        var retained: [CVMetalTexture] = []
        var timings = FrameTimings()

        init(frame: VideoFrame, settings: PipelineSettings) {
            self.frame = frame
            self.settings = settings
        }
    }

    private let context: MetalContext
    private let renderer: FrameRenderer
    private let segmenter: PersonSegmenter
    private let gate = InFlightGate()
    private let stats = StatsCollector()
    private let shared: Mutex<Shared>
    private let queue = DispatchQueue(label: "StyleKit.StylePipeline", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "StyleKit.StylePipeline.output", qos: .userInteractive)
    private let predictorQueue = DispatchQueue(label: "StyleKit.StylePipeline.predictor", qos: .userInitiated)
    private let statsTimer: any DispatchSourceTimer

    private var engines: [Quality: StyleEngine] = [:]
    private var loadingEngines: Set<Quality> = []
    private var failedEngines: Set<Quality> = []
    private var activeEngine: StyleEngine?
    private var predictor = PredictorState.idle
    private var contentVector: StyleVector?
    private var contentPending = false
    private var lastContentTime: CMTime?
    private var lastStyle: StyleVector?

    public init(modelStore: ModelStore, settings: PipelineSettings = PipelineSettings(),
                backpressure: Backpressure = .dropFrames, outputWidth: Int = 1280, outputHeight: Int = 720) throws {
        self.modelStore = modelStore
        self.backpressure = backpressure
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        context = try MetalContext()
        renderer = try FrameRenderer(context: context, outputWidth: outputWidth, outputHeight: outputHeight)
        segmenter = PersonSegmenter(device: context.device)
        shared = Mutex(Shared(settings: settings))
        statsTimer = DispatchSource.makeTimerSource(queue: outputQueue)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer.setEventHandler { [weak self] in self?.publishStats() }
        statsTimer.resume()
    }

    deinit {
        statsTimer.cancel()
        shared.withLock { $0.statsContinuations.values.forEach { $0.finish() } }
    }

    public var settings: PipelineSettings {
        get { shared.withLock { $0.settings } }
        set { shared.withLock { $0.settings = newValue } }
    }

    public func updateSettings(_ change: (inout PipelineSettings) -> Void) {
        shared.withLock { change(&$0.settings) }
    }

    public func addOutput(_ output: any FrameOutput) {
        shared.withLock { $0.outputs.append(output) }
    }

    public func removeOutput(_ output: any FrameOutput) {
        shared.withLock { $0.outputs.removeAll { $0 === output } }
    }

    /// Called on the output queue for every frame, after the outputs got it.
    public var onFrame: (@Sendable (ProcessedFrame) -> Void)? {
        get { shared.withLock { $0.onFrame } }
        set { shared.withLock { $0.onFrame = newValue } }
    }

    /// Called about once per second.
    public var onStats: (@Sendable (PipelineStats) -> Void)? {
        get { shared.withLock { $0.onStats } }
        set { shared.withLock { $0.onStats = newValue } }
    }

    public func statsUpdates() -> AsyncStream<PipelineStats> {
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineStats.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        shared.withLock { $0.statsContinuations[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.shared.withLock { _ = $0.statsContinuations.removeValue(forKey: id) }
        }
        return stream
    }

    /// Loads the engine for the current quality and the style predictor, so the first frames are stylized.
    /// Without it they are loaded on demand and frames pass through unstylized meanwhile.
    public func prepare() async throws {
        let quality = settings.quality
        let engine = try await StyleEngine.load(store: modelStore, size: quality.size, mode: quality.mode)
        let predictor = try await StylePredictor.load(from: modelStore)
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                engines[quality] = engine
                failedEngines.remove(quality)
                self.predictor = .ready(predictor)
                continuation.resume()
            }
        }
    }

    public var frameHandler: FrameHandler {
        { [weak self] frame in self?.submit(frame) }
    }

    public func start(source: any FrameSource) throws {
        stop()
        try source.start(handler: frameHandler)
        shared.withLock { $0.source = source }
    }

    public func stop() {
        let source = shared.withLock { shared -> (any FrameSource)? in
            defer { shared.source = nil }
            return shared.source
        }
        source?.stop()
    }

    public func submit(_ frame: VideoFrame) {
        stats.recordCapture()
        switch backpressure {
        case .dropFrames:
            guard gate.tryEnter() else {
                stats.recordDrop()
                return
            }
        case .waitForSlot:
            gate.enter()
        }
        let job = Job(frame: frame, settings: settings)
        queue.async { [self] in begin(job) }
    }

    /// Returns once every admitted frame has been output or dropped.
    public func waitUntilIdle() async {
        let gate = gate
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                gate.waitUntilEmpty()
                continuation.resume()
            }
        }
    }

    // MARK: - Pipeline queue

    private func begin(_ job: Job) {
        let settings = job.settings
        guard !settings.bypass, let style = settings.style else {
            // Stylized frames still in flight would land after this one.
            if activeEngine != nil {
                guard gate.current == 1 else { return drop() }
                activate(nil)
            }
            return encodeBypass(job)
        }
        if engines[settings.quality] == nil { loadEngine(settings.quality) }
        if let wanted = engines[settings.quality], wanted !== activeEngine {
            if activeEngine != nil && gate.current > 1 { return drop() }
            activate(wanted)
        }
        guard let engine = activeEngine else { return encodeBypass(job) }

        job.resetHistory = style != lastStyle
        lastStyle = style
        job.style = style
        if settings.strength < 1 {
            if let contentVector { job.style = style.blended(withContent: contentVector, strength: max(0, settings.strength)) }
            if case .ready(let predictor) = predictor, !contentPending, contentVectorDue(job.frame.presentationTime) {
                let camera = job.frame.pixelBuffer
                job.predictorInput = try? StylePredictor.makeBuffer(predictor.inputSize(forWidth: camera.width, height: camera.height))
                contentPending = job.predictorInput != nil
                lastContentTime = job.frame.presentationTime
            } else if case .idle = predictor {
                loadPredictor()
            }
        }

        do {
            let input = try engine.makeInputBuffer()
            job.input = input
            let commandBuffer = try context.makeCommandBuffer()
            job.retained = try renderer.encodeDownscale(camera: job.frame.pixelBuffer, into: input,
                                                        predictorInput: job.predictorInput, commandBuffer: commandBuffer)
            commandBuffer.addCompletedHandler { [self] buffer in
                let milliseconds = Self.gpuMilliseconds(buffer)
                let error = buffer.error
                queue.async { [self] in downscaled(job, engine: engine, gpuMilliseconds: milliseconds, error: error) }
            }
            commandBuffer.commit()
        } catch {
            if job.predictorInput != nil { contentPending = false }
            fail(error)
        }
    }

    private func downscaled(_ job: Job, engine: StyleEngine, gpuMilliseconds: Double, error: (any Error)?) {
        job.retained = []
        if let predictorInput = job.predictorInput {
            if error == nil, case .ready(let predictor) = predictor {
                updateContentVector(predictor, from: predictorInput)
            } else {
                contentPending = false
            }
        }
        guard error == nil, let input = job.input, let style = job.style else { return fail(error) }
        job.timings.downscaleMilliseconds = gpuMilliseconds
        if job.settings.mask != .everything {
            segmenter.submit(input, quality: job.settings.segmentationQuality)
        }
        engine.stylize(input, style: style) { [self] result in
            queue.async { [self] in stylized(job, result: result) }
        }
    }

    private func stylized(_ job: Job, result: Result<StylizedFrame, any Error>) {
        switch result {
        case .failure(let error):
            fail(error)
        case .success(let frame):
            guard let input = job.input else { return fail(nil) }
            job.stylized = frame.pixelBuffer
            job.timings.inferenceMilliseconds = frame.inferenceMilliseconds
            job.timings.device = frame.device
            let settings = job.settings
            let options = PostOptions(smoothing: settings.smoothing, upsampling: settings.upsampling, detail: settings.detail,
                                      preserveColors: settings.preserveColors, mask: settings.mask,
                                      resetHistory: job.resetHistory)
            do {
                let commandBuffer = try context.makeCommandBuffer()
                let (output, owners) = try renderer.encodeStylized(
                    camera: job.frame.pixelBuffer, input: input, stylized: frame.pixelBuffer,
                    mask: settings.mask == .everything ? nil : segmenter.latestMask, options: options, commandBuffer: commandBuffer)
                job.retained = owners
                commit(job, output: output, stylized: true, commandBuffer: commandBuffer)
            } catch {
                fail(error)
            }
        }
    }

    private func encodeBypass(_ job: Job) {
        do {
            let commandBuffer = try context.makeCommandBuffer()
            let (output, owners) = try renderer.encodeBypass(camera: job.frame.pixelBuffer, commandBuffer: commandBuffer)
            job.retained = owners
            commit(job, output: output, stylized: false, commandBuffer: commandBuffer)
        } catch {
            fail(error)
        }
    }

    private func commit(_ job: Job, output: CVPixelBuffer, stylized: Bool, commandBuffer: any MTLCommandBuffer) {
        let box = UncheckedBox(output)
        commandBuffer.addCompletedHandler { [self] buffer in
            let milliseconds = Self.gpuMilliseconds(buffer)
            let error = buffer.error
            outputQueue.async { [self] in
                deliver(job, output: box.value, stylized: stylized, postMilliseconds: milliseconds, error: error)
            }
        }
        commandBuffer.commit()
    }

    private func activate(_ engine: StyleEngine?) {
        activeEngine = engine
        gate.setLimit(engine?.maxConcurrentFrames ?? 1)
        renderer.resetHistory()
        let description = engine.map { "\($0.size) \($0.mode.rawValue)" }
        shared.withLock { $0.engine = description }
    }

    private func loadEngine(_ quality: Quality) {
        guard !loadingEngines.contains(quality), !failedEngines.contains(quality) else { return }
        loadingEngines.insert(quality)
        let store = modelStore
        Task { [self] in
            do {
                let engine = try await StyleEngine.load(store: store, size: quality.size, mode: quality.mode)
                queue.async { [self] in
                    loadingEngines.remove(quality)
                    engines[quality] = engine
                }
            } catch {
                queue.async { [self] in
                    loadingEngines.remove(quality)
                    failedEngines.insert(quality)
                }
                record(error)
            }
        }
    }

    private func loadPredictor() {
        predictor = .loading
        let store = modelStore
        Task { [self] in
            do {
                let loaded = try await StylePredictor.load(from: store)
                queue.async { [self] in predictor = .ready(loaded) }
            } catch {
                queue.async { [self] in predictor = .failed }
                record(error)
            }
        }
    }

    private func contentVectorDue(_ time: CMTime) -> Bool {
        guard let lastContentTime else { return true }
        return time < lastContentTime || time - lastContentTime >= Self.contentVectorInterval
    }

    private func updateContentVector(_ predictor: StylePredictor, from buffer: CVPixelBuffer) {
        let box = UncheckedBox(buffer)
        predictorQueue.async { [self] in
            let vector = try? predictor.vector(for: box.value)
            queue.async { [self] in
                if let vector { contentVector = vector }
                contentPending = false
            }
        }
    }

    private func drop() {
        stats.recordDrop()
        gate.leave()
    }

    private func fail(_ error: (any Error)?) {
        if let error { record(error) }
        drop()
    }

    private func record(_ error: any Error) {
        shared.withLock { $0.lastError = String(describing: error) }
    }

    // MARK: - Output queue

    private func deliver(_ job: Job, output: CVPixelBuffer, stylized: Bool, postMilliseconds: Double, error: (any Error)?) {
        job.retained = []
        guard error == nil else { return fail(error) }
        job.timings.postMilliseconds = postMilliseconds
        job.timings.totalMilliseconds = HostClock.milliseconds(since: job.admitted)
        job.timings.latencyMilliseconds = HostClock.milliseconds(since: job.frame.hostTime)
        let (outputs, onFrame) = shared.withLock { ($0.outputs, $0.onFrame) }
        for destination in outputs {
            destination.publish(output, time: job.frame.presentationTime)
        }
        onFrame?(ProcessedFrame(output: output, source: job.frame, stylized: stylized, timings: job.timings))
        stats.recordOutput(job.timings)
        gate.leave()
    }

    private func publishStats() {
        let (engine, lastError, onStats, continuations) = shared.withLock {
            ($0.engine, $0.lastError, $0.onStats, Array($0.statsContinuations.values))
        }
        let snapshot = stats.snapshot(engine: engine, lastError: lastError)
        onStats?(snapshot)
        for continuation in continuations { continuation.yield(snapshot) }
    }

    private static func gpuMilliseconds(_ buffer: any MTLCommandBuffer) -> Double {
        (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
    }
}
