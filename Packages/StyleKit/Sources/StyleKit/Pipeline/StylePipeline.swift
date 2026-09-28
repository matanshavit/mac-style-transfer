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
/// Settings can change from any thread and apply from the next admitted frame. Each engine instance works on one frame
/// at a time and one more frame waits for the next free instance. In `.dropFrames` mode a newer frame replaces the
/// waiting one, so latency never queues up; in `.waitForSlot` mode the source's thread blocks instead (for offline runs).
///
/// An adaptive quality only adapts in `.dropFrames` mode; `.waitForSlot` runs its preferred configuration. At most two
/// engines stay loaded, the running one and the one being switched to or the adaptive fallback, plus an adaptive trial
/// while one runs.
///
/// A size without a model for the chosen network, or whose engine failed to load or keeps failing, runs classic, so the
/// choice of network never stops frames from being stylized.
public final class StylePipeline: @unchecked Sendable {
    public enum Backpressure: Sendable {
        case dropFrames
        case waitForSlot
    }

    public static let contentVectorInterval = CMTime(value: 1, timescale: 2)
    /// Frames in a row that fail to stylize before their engine is treated like one that failed to load.
    private static let failedFrameLimit = 30

    public let modelStore: ModelStore
    public let outputWidth = 1280
    public let outputHeight = 720
    public let backpressure: Backpressure

    private struct Shared: Sendable {
        var settings: PipelineSettings
        var outputs: [any FrameOutput] = []
        var onFrame: (@Sendable (ProcessedFrame) -> Void)?
        var onStats: (@Sendable (PipelineStats) -> Void)?
        var onAdaptiveEvent: (@Sendable (AdaptiveEvent) -> Void)?
        var statsContinuations: [UUID: AsyncStream<PipelineStats>.Continuation] = [:]
        var source: (any FrameSource)?
        var engine: String?
        var adaptive: AdaptiveDecision?
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
        var usesEngine = false
        var quality: Quality?
        var dualEngine = false
        var resetHistory = false
        var input: CVPixelBuffer?
        var predictorInput: CVPixelBuffer?
        var needsContentVector = false
        var trialEngine: StyleEngine?
        /// The trial engine's input when its size differs from the running engine's.
        var trialInput: CVPixelBuffer?
        /// Held until the post pass completes so the engine's pool cannot reuse it while the GPU reads it.
        var stylized: CVPixelBuffer?
        var retained: [CVMetalTexture] = []
        var timings = FrameTimings()

        init(frame: VideoFrame, settings: PipelineSettings) {
            self.frame = frame
            self.settings = settings
        }
    }

    private struct Delivery {
        let job: Job
        let output: CVPixelBuffer
        let stylized: Bool
        let release: CMTime
    }

    private struct DeviceAge {
        var seconds: Double
        var lastOutput: CMTime
    }

    private struct EngineKey: Hashable {
        var network: StyleNetwork
        var quality: Quality
    }

    private let context: MetalContext
    private let renderer: FrameRenderer
    private let segmenter: PersonSegmenter
    private let admission = InFlightGate(limit: 2)
    private let inFlight = InFlightGate()
    private let stats = StatsCollector()
    private let shared: Mutex<Shared>
    private let queue = DispatchQueue(label: "StyleKit.StylePipeline", qos: .userInteractive)
    private let outputQueue = DispatchQueue(label: "StyleKit.StylePipeline.output", qos: .userInteractive)
    private let predictorQueue = DispatchQueue(label: "StyleKit.StylePipeline.predictor", qos: .userInitiated)
    private let statsTimer: any DispatchSourceTimer
    private let releaseTimer: any DispatchSourceTimer

    private let adaptive: AdaptiveController
    private var conditionsMonitor: SystemConditionsMonitor?
    private let modelSizes: [StyleNetwork: [ModelSize]]
    private var network: StyleNetwork
    private var engines: [EngineKey: StyleEngine] = [:]
    private var keptEngines: [EngineKey] = []
    private var loadingEngines: Set<EngineKey> = []
    private var failedEngines: Set<EngineKey> = []
    private var activeEngine: StyleEngine?
    /// The engine that ran last. It stays loaded while frames pass through.
    private var currentKey: EngineKey?
    private var wantedQuality: Quality?
    private var trialBusy = false
    private var engineFrames = 0
    private var failedFrames = 0
    private var waiting: [Job] = []
    private var segmentation: SegmentationQuality?
    private var predictor = PredictorState.idle
    private var contentVector: StyleVector?
    private var contentPending = false
    private var lastContentTime: CMTime?
    private var lastStyle: StyleVector?

    private var held: [Delivery] = []
    private var deviceAges: [ComputeDevice: DeviceAge] = [:]

    public init(modelStore: ModelStore, settings: PipelineSettings = PipelineSettings(),
                backpressure: Backpressure = .dropFrames) throws {
        self.modelStore = modelStore
        self.backpressure = backpressure
        context = try MetalContext()
        renderer = try FrameRenderer(context: context, outputWidth: outputWidth, outputHeight: outputHeight)
        segmenter = PersonSegmenter(device: context.device)
        adaptive = AdaptiveController(conditions: .current())
        modelSizes = Dictionary(uniqueKeysWithValues: StyleNetwork.allCases.map { network in
            (network, modelStore.availableTransformerSizes(for: network))
        })
        network = settings.network
        shared = Mutex(Shared(settings: settings))
        statsTimer = DispatchSource.makeTimerSource(queue: outputQueue)
        releaseTimer = DispatchSource.makeTimerSource(flags: .strict, queue: outputQueue)
        statsTimer.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer.setEventHandler { [weak self] in self?.publishStats() }
        statsTimer.resume()
        releaseTimer.setEventHandler { [weak self] in self?.deliverHeld() }
        releaseTimer.resume()
        adaptive.onEvent = { [weak self] event in self?.adaptiveEvent(event) }
        conditionsMonitor = SystemConditionsMonitor(queue: queue) { [weak self] in self?.conditionsChanged() }
    }

    deinit {
        statsTimer.cancel()
        releaseTimer.cancel()
        shared.withLock { $0.statsContinuations.values.forEach { $0.finish() } }
    }

    public var settings: PipelineSettings {
        shared.withLock { $0.settings }
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

    /// Called on the pipeline queue when an adaptive quality decides, starts a trial or switches engines. Keep it short.
    public var onAdaptiveEvent: (@Sendable (AdaptiveEvent) -> Void)? {
        get { shared.withLock { $0.onAdaptiveEvent } }
        set { shared.withLock { $0.onAdaptiveEvent = newValue } }
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
    /// Without it they are loaded on demand and frames pass through unstylized meanwhile. Frames that arrive while it
    /// runs pass through too, and wait for its engine instead of loading a second copy.
    public func prepare() async throws {
        let wanted = await withCheckedContinuation { continuation in
            queue.async { [self] in
                let settings = settings
                network = settings.network
                let quality = engineQuality(for: settings.quality)
                if wantedQuality == nil { wantedQuality = quality }
                continuation.resume(returning: engineKey(for: quality))
            }
        }
        let key: EngineKey
        let engine: StyleEngine
        let predictor: StylePredictor
        do {
            (key, engine) = try await loadEngineOrClassic(wanted)
            predictor = try await StylePredictor.load(from: modelStore)
        } catch {
            queue.async { [self] in manageEngines() }
            throw error
        }
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if engines[key] == nil, wantedQuality == key.quality { engines[key] = engine }
                failedEngines.remove(key)
                manageEngines()
                self.predictor = .ready(predictor)
                continuation.resume()
            }
        }
    }

    private func loadEngineOrClassic(_ wanted: EngineKey) async throws -> (EngineKey, StyleEngine) {
        do {
            return (wanted, try await Self.loadEngine(wanted, from: modelStore))
        } catch {
            let fallback = await withCheckedContinuation { continuation in
                queue.async { [self] in
                    failedEngines.insert(wanted)
                    continuation.resume(returning: engineKey(for: wanted.quality))
                }
            }
            guard fallback != wanted else { throw error }
            record(error)
            return (fallback, try await Self.loadEngine(fallback, from: modelStore))
        }
    }

    public var frameHandler: FrameHandler {
        { [weak self] frame in self?.submit(frame) }
    }

    public func start(source: any FrameSource) throws {
        stop()
        queue.async { [self] in resetSourceState() }
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
        if backpressure == .waitForSlot { admission.enter() }
        inFlight.enter()
        let job = Job(frame: frame, settings: settings)
        queue.async { [self] in schedule(job) }
    }

    /// Returns once every admitted frame has been output or dropped.
    public func waitUntilIdle() async {
        let inFlight = inFlight
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                inFlight.waitUntilEmpty()
                continuation.resume()
            }
        }
    }

    // MARK: - Pipeline queue

    private func schedule(_ job: Job) {
        adaptive.recordArrival(job.frame.presentationTime)
        if backpressure == .dropFrames {
            waiting.forEach(drop)
            waiting.removeAll()
        }
        waiting.append(job)
        startWaiting()
    }

    private func startWaiting() {
        while let job = waiting.first, canStart(job) {
            waiting.removeFirst()
            start(job)
        }
    }

    /// Frames from the previous engine, or stylized frames before a passthrough one, must all be posted first so
    /// outputs stay in order.
    private func canStart(_ job: Job) -> Bool {
        guard let engine = engine(for: job.settings) else { return engineFrames == 0 }
        if engine !== activeEngine { return engineFrames == 0 }
        return engineFrames < engine.maxConcurrentFrames
    }

    /// Nil passes the frame through. The active engine keeps running while the wanted one loads.
    private func engine(for settings: PipelineSettings) -> StyleEngine? {
        guard settings.style != nil else { return nil }
        let networkChanged = settings.network != network
        network = settings.network
        let quality = engineQuality(for: settings.quality)
        if quality != wantedQuality || networkChanged {
            wantedQuality = quality
            manageEngines()
        }
        if networkChanged { describeEngine() }
        return engines[engineKey(for: quality)] ?? activeEngine
    }

    private func engineQuality(for quality: Quality) -> Quality {
        guard backpressure == .dropFrames, quality.adaptive else {
            if adaptive.stop() { shared.withLock { $0.adaptive = nil } }
            return quality.fixed
        }
        let sizes = ModelSize.standard.filter { size in
            [network, .classic].contains { modelSizes[$0]?.contains(size) == true }
        }
        return adaptive.target(for: quality, sizes: sizes, current: currentKey?.quality, now: HostClock.now().seconds)
    }

    /// The chosen network, or classic where the chosen one has no model or its engine failed.
    private func engineKey(for quality: Quality) -> EngineKey {
        let chosen = EngineKey(network: network, quality: quality)
        guard !hasModel(chosen), modelSizes[.classic]?.contains(quality.size) == true else { return chosen }
        return EngineKey(network: .classic, quality: quality)
    }

    private func hasModel(_ key: EngineKey) -> Bool {
        modelSizes[key.network]?.contains(key.quality.size) == true && !failedEngines.contains(key)
    }

    private func start(_ job: Job) {
        let settings = job.settings
        let engine = engine(for: settings)
        if engine !== activeEngine { activate(engine) }
        let segmentation = engine != nil && settings.mask != .everything ? settings.segmentationQuality : nil
        if segmentation != self.segmentation {
            segmenter.reset()
            self.segmentation = segmentation
        }
        guard let engine, let style = settings.style else { return encodeBypass(job) }

        engineFrames += 1
        job.usesEngine = true
        job.quality = engine.quality
        job.timings.network = engine.network
        job.dualEngine = engine.mode == .dual
        job.resetHistory = style != lastStyle
        lastStyle = style
        job.style = style
        requestContentVector(for: job)
        assignTrial(to: job, running: engine)

        do {
            let input = try engine.makeInputBuffer()
            job.input = input
            let commandBuffer = try context.makeCommandBuffer()
            job.retained = try renderer.encodeDownscale(camera: job.frame.pixelBuffer,
                                                        into: [input, job.predictorInput, job.trialInput].compactMap { $0 },
                                                        commandBuffer: commandBuffer)
            commandBuffer.addCompletedHandler { [self] buffer in
                let milliseconds = Self.gpuMilliseconds(buffer)
                let error = buffer.error
                queue.async { [self] in downscaled(job, engine: engine, gpuMilliseconds: milliseconds, error: error) }
            }
            commandBuffer.commit()
        } catch {
            if job.predictorInput != nil && !job.needsContentVector { contentPending = false }
            fail(job, error)
        }
    }

    /// Strength below 1 blends toward the content's own vector. The first frame computes it before stylizing so it
    /// does not flash at full strength; later frames refresh it in the background.
    private func requestContentVector(for job: Job) {
        guard job.settings.strength < 1 else {
            contentVector = nil
            return
        }
        switch predictor {
        case .idle:
            loadPredictor()
        case .ready(let predictor):
            let time = job.frame.presentationTime
            job.needsContentVector = contentVector == nil
            guard job.needsContentVector || (!contentPending && contentVectorDue(time)) else { return }
            let camera = job.frame.pixelBuffer
            job.predictorInput = try? StylePredictor.makeBuffer(predictor.inputSize(forWidth: camera.width, height: camera.height))
            if job.predictorInput != nil && !job.needsContentVector { contentPending = true }
            lastContentTime = time
        case .loading, .failed:
            break
        }
    }

    private func downscaled(_ job: Job, engine: StyleEngine, gpuMilliseconds: Double, error: (any Error)?) {
        job.retained = []
        if let predictorInput = job.predictorInput, case .ready(let predictor) = predictor {
            if job.needsContentVector {
                if error == nil, let vector = try? predictor.vector(for: predictorInput) { contentVector = vector }
            } else if error == nil {
                updateContentVector(predictor, from: predictorInput)
            } else {
                contentPending = false
            }
        }
        guard error == nil, let input = job.input, let requested = job.style else { return fail(job, error) }
        let style = if job.settings.strength < 1, let contentVector {
            requested.blended(withContent: contentVector, strength: max(0, job.settings.strength))
        } else {
            requested
        }
        job.timings.downscaleMilliseconds = gpuMilliseconds
        if job.settings.mask != .everything {
            segmenter.submit(input, quality: job.settings.segmentationQuality)
        }
        engine.stylize(input, style: style) { [self] result in
            queue.async { [self] in stylized(job, engine: engine, style: style, result: result) }
        }
    }

    private func stylized(_ job: Job, engine: StyleEngine, style: StyleVector, result: Result<StylizedFrame, any Error>) {
        switch result {
        case .failure(let error):
            stylizeFailed(on: engine)
            fail(job, error)
        case .success(let frame):
            failedFrames = 0
            guard let input = job.input else { return fail(job, nil) }
            let trialEngine = job.trialEngine
            job.trialEngine = nil
            defer { if let trialEngine { runTrial(trialEngine, input: job.trialInput ?? input, style: style) } }
            job.stylized = frame.pixelBuffer
            job.timings.inferenceMilliseconds = frame.inferenceMilliseconds
            job.timings.device = frame.device
            let settings = job.settings
            let options = PostOptions(smoothing: settings.smoothing, upsampling: settings.upsampling,
                                      detail: min(max(settings.detail, 0), 1), preserveColors: settings.preserveColors,
                                      mask: settings.mask, resetHistory: job.resetHistory)
            do {
                let commandBuffer = try context.makeCommandBuffer()
                let (output, owners) = try renderer.encodeStylized(
                    camera: job.frame.pixelBuffer, input: input, stylized: frame.pixelBuffer,
                    mask: settings.mask == .everything ? nil : segmenter.latestMask, options: options, commandBuffer: commandBuffer)
                job.retained = owners
                commit(job, output: output, stylized: true, commandBuffer: commandBuffer)
            } catch {
                fail(job, error)
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
            fail(job, error)
        }
    }

    private func commit(_ job: Job, output: CVPixelBuffer, stylized: Bool, commandBuffer: any MTLCommandBuffer) {
        let box = UncheckedBox(output)
        commandBuffer.addCompletedHandler { [self] buffer in
            let milliseconds = Self.gpuMilliseconds(buffer)
            let error = buffer.error
            outputQueue.async { [self] in
                posted(job, output: box.value, stylized: stylized, postMilliseconds: milliseconds, error: error)
            }
        }
        commandBuffer.commit()
        leftEngine(job)
    }

    /// The frame's post pass is committed or the frame failed before that.
    private func leftEngine(_ job: Job) {
        if job.usesEngine { engineFrames -= 1 }
        if job.trialEngine != nil {
            job.trialEngine = nil
            trialBusy = false
        }
        if backpressure == .waitForSlot { admission.leave() }
        startWaiting()
    }

    /// Temporal history carries over between engines of the same size, so switching devices does not reset smoothing.
    private func activate(_ engine: StyleEngine?) {
        if activeEngine == nil { renderer.resetHistory() }
        activeEngine = engine
        failedFrames = 0
        admission.setLimit((engine?.maxConcurrentFrames ?? 1) + 1)
        describeEngine()
        guard let engine else { return }
        currentKey = EngineKey(network: engine.network, quality: engine.quality)
        manageEngines()
        if adaptive.decision != nil { adaptiveEvent(.switched(engine.quality)) }
    }

    /// Says why the active engine runs classic when another network is chosen, unless it only runs until the chosen
    /// network's engine is loaded.
    private func describeEngine() {
        let description = activeEngine.map { engine in
            let text = "\(engine.size) \(engine.mode.rawValue) \(engine.network.rawValue)"
            let chosen = EngineKey(network: network, quality: engine.quality)
            guard engine.network != network, engineKey(for: engine.quality) != chosen else { return text }
            return text + (failedEngines.contains(chosen) ? " (\(network) failed)" : " (no \(network) model)")
        }
        shared.withLock { $0.engine = description }
    }

    private func resetSourceState() {
        contentVector = nil
        lastContentTime = nil
        segmenter.reset()
        renderer.resetHistory()
    }

    /// Keeps the engine that ran last and the one wanted next or else the adaptive fallback, plus the adaptive trial,
    /// and unloads the rest. An engine still referenced by frames in flight is freed when they finish.
    private func manageEngines() {
        var keep: [EngineKey] = []
        let wanted = (adaptive.decision?.quality ?? wantedQuality).map(engineKey)
        let trial = adaptive.trialQuality.map(engineKey)
        for key in [currentKey, wanted, trial, adaptive.fallback.map(engineKey)].compactMap({ $0 })
        where keep.count < (trial == nil ? 2 : 3) && !keep.contains(key) {
            keep.append(key)
        }
        guard keep != keptEngines else { return }
        keptEngines = keep
        engines = engines.filter { keep.contains($0.key) }
        for key in keep where engines[key] == nil { loadEngine(key) }
    }

    private func loadEngine(_ key: EngineKey) {
        guard !loadingEngines.contains(key) else { return }
        guard !failedEngines.contains(key) else { return queue.async { [self] in engineFailed(key) } }
        loadingEngines.insert(key)
        let store = modelStore
        Task { [self] in
            do {
                let engine = try await Self.loadEngine(key, from: store)
                queue.async { [self] in
                    loadingEngines.remove(key)
                    if keptEngines.contains(key), engines[key] == nil { engines[key] = engine }
                }
            } catch {
                queue.async { [self] in
                    loadingEngines.remove(key)
                    failedEngines.insert(key)
                    engineFailed(key)
                }
                record(error)
            }
        }
    }

    private static func loadEngine(_ key: EngineKey, from store: ModelStore) async throws -> StyleEngine {
        try await StyleEngine.load(store: store, network: key.network, size: key.quality.size, mode: key.quality.mode)
    }

    /// Unloads an engine whose frames keep failing. Frames pass through until the engine that replaces it runs.
    private func stylizeFailed(on engine: StyleEngine) {
        guard engine === activeEngine else { return }
        failedFrames += 1
        guard failedFrames == Self.failedFrameLimit else { return }
        let key = EngineKey(network: engine.network, quality: engine.quality)
        failedEngines.insert(key)
        engines[key] = nil
        currentKey = nil
        activate(nil)
        engineFailed(key)
    }

    /// A failed network other than classic falls back to classic at that size. A failed classic engine drops the
    /// adaptive step.
    private func engineFailed(_ key: EngineKey) {
        if engineKey(for: key.quality) != key {
            describeEngine()
            manageEngines()
        } else if adaptive.engineFailed(key.quality) {
            manageEngines()
        }
    }

    /// A trial runs on at most one frame at a time, after that frame's own inference.
    private func assignTrial(to job: Job, running engine: StyleEngine) {
        guard !trialBusy, let quality = adaptive.trialQuality,
              let trialEngine = engines[engineKey(for: quality)] else { return }
        if trialEngine.size != engine.size {
            guard let input = try? trialEngine.makeInputBuffer() else { return }
            job.trialInput = input
        }
        job.trialEngine = trialEngine
        trialBusy = true
    }

    /// Runs after the frame's post pass is committed, so a trial on a busy GPU does not delay the frame being output.
    private func runTrial(_ engine: StyleEngine, input: CVPixelBuffer, style: StyleVector) {
        engine.stylize(input, style: style) { [self] result in
            let milliseconds = try? result.get().inferenceMilliseconds
            queue.async { [self] in
                trialBusy = false
                if let milliseconds {
                    adaptive.recordTrial(on: engine.quality, inference: milliseconds, now: HostClock.now().seconds)
                    manageEngines()
                }
            }
        }
    }

    private func recordAdaptiveFrame(_ quality: Quality, timings: FrameTimings) {
        adaptive.recordFrame(on: quality, inference: timings.inferenceMilliseconds, total: timings.totalMilliseconds,
                             now: HostClock.now().seconds)
        manageEngines()
    }

    private func conditionsChanged() {
        adaptive.update(.current(), now: HostClock.now().seconds)
        manageEngines()
    }

    private func adaptiveEvent(_ event: AdaptiveEvent) {
        let onEvent = shared.withLock { shared in
            if case .decided(let decision) = event { shared.adaptive = decision }
            return shared.onAdaptiveEvent
        }
        onEvent?(event)
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
                if let vector, contentVector != nil { contentVector = vector }
                contentPending = false
            }
        }
    }

    private func fail(_ job: Job, _ error: (any Error)?) {
        if let error { record(error) }
        leftEngine(job)
        drop(job)
    }

    private func drop(_ job: Job) {
        stats.recordDrop()
        inFlight.leave()
    }

    private func record(_ error: any Error) {
        shared.withLock { $0.lastError = String(describing: error) }
    }

    // MARK: - Output queue

    private func posted(_ job: Job, output: CVPixelBuffer, stylized: Bool, postMilliseconds: Double, error: (any Error)?) {
        job.retained = []
        if let error {
            record(error)
            return drop(job)
        }
        job.timings.postMilliseconds = postMilliseconds
        held.append(Delivery(job: job, output: output, stylized: stylized, release: releaseTime(for: job)))
        deliverHeld()
    }

    /// In dual mode the GPU and the Neural Engine take different times, so alternating frames would come out unevenly
    /// spaced. While both are in use, each frame is held until it is as old as a typical frame from the slower one.
    private func releaseTime(for job: Job) -> CMTime {
        let now = HostClock.now()
        guard job.dualEngine, let device = job.timings.device else { return now }
        let age = (now - job.admitted).seconds
        let smoothed = deviceAges[device].map { $0.seconds + 0.1 * (age - $0.seconds) } ?? age
        deviceAges[device] = DeviceAge(seconds: smoothed, lastOutput: now)
        let recent = deviceAges.values.filter { (now - $0.lastOutput).seconds < 0.5 }
        guard recent.count > 1, let target = recent.map(\.seconds).max(), age < target else { return now }
        return job.admitted + CMTime(seconds: target, preferredTimescale: 1_000_000_000)
    }

    private func deliverHeld() {
        while let next = held.first {
            let wait = (next.release - HostClock.now()).seconds
            if wait > 0 {
                releaseTimer.schedule(deadline: .now() + wait, leeway: .nanoseconds(0))
                return
            }
            held.removeFirst()
            deliver(next)
        }
    }

    private func deliver(_ delivery: Delivery) {
        let job = delivery.job
        job.timings.totalMilliseconds = HostClock.milliseconds(since: job.admitted)
        job.timings.latencyMilliseconds = HostClock.milliseconds(since: job.frame.hostTime)
        let (outputs, onFrame) = shared.withLock { ($0.outputs, $0.onFrame) }
        for destination in outputs {
            destination.publish(delivery.output, time: job.frame.presentationTime)
        }
        onFrame?(ProcessedFrame(output: delivery.output, source: job.frame, stylized: delivery.stylized, timings: job.timings))
        stats.recordOutput(job.timings)
        if let quality = job.quality {
            let timings = job.timings
            queue.async { [self] in recordAdaptiveFrame(quality, timings: timings) }
        }
        inFlight.leave()
    }

    private func publishStats() {
        let (engine, adaptive, lastError, onStats, continuations) = shared.withLock {
            ($0.engine, $0.adaptive, $0.lastError, $0.onStats, Array($0.statsContinuations.values))
        }
        let snapshot = stats.snapshot(engine: engine, adaptive: adaptive, lastError: lastError)
        onStats?(snapshot)
        for continuation in continuations { continuation.yield(snapshot) }
    }

    private static func gpuMilliseconds(_ buffer: any MTLCommandBuffer) -> Double {
        (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
    }
}
