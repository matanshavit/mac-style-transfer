import CoreMedia
import Foundation

/// The configuration auto quality runs, or is switching to, and why.
public struct AdaptiveDecision: Sendable, Equatable, CustomStringConvertible {
    public var quality: Quality
    public var reason: AdaptiveReason

    public var description: String { "\(quality): \(reason)" }
}

/// Times are p50 milliseconds from admission to output. The budget is 65% of the camera's frame interval per engine
/// instance, and a trial must fit in 90% of it.
public enum AdaptiveReason: Sendable, Equatable, CustomStringConvertible {
    case preferred
    /// Waits on the Neural Engine for a trial of a higher step.
    case pendingTrial
    case slowFrames(Quality, milliseconds: Double, budget: Double)
    /// A trial run of this configuration next to the one below fit.
    case trialFit(milliseconds: Double, limit: Double)
    case trialTooSlow(Quality, milliseconds: Double, limit: Double)
    case engineFailed(Quality)
    case lowPowerMode
    case batteryPower
    case thermalState(ProcessInfo.ThermalState)

    public var description: String {
        switch self {
        case .preferred: "preferred"
        case .pendingTrial: "waiting for a trial of a higher step"
        case .slowFrames(let quality, let milliseconds, let budget):
            "\(quality) took \(Self.format(milliseconds)) ms, budget \(Self.format(budget)) ms"
        case .trialFit(let milliseconds, let limit): "trial took \(Self.format(milliseconds)) ms, limit \(Self.format(limit)) ms"
        case .trialTooSlow(let quality, let milliseconds, let limit):
            "\(quality) trial took \(Self.format(milliseconds)) ms, limit \(Self.format(limit)) ms"
        case .engineFailed(let quality): "\(quality) failed to load"
        case .lowPowerMode: "Low Power Mode"
        case .batteryPower: "on battery"
        case .thermalState(let state): "thermal state \(Self.name(state))"
        }
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

public enum AdaptiveEvent: Sendable, CustomStringConvertible {
    /// A new configuration or reason. The engine switches once the new one is loaded and the running one is idle.
    case decided(AdaptiveDecision)
    /// A higher step started running on copies of the frames, next to the step being output.
    case trialStarted(Quality)
    /// Output frames now come from this configuration.
    case switched(Quality)

    public var description: String {
        switch self {
        case .decided(let decision): "decided \(decision)"
        case .trialStarted(let quality): "trial of \(quality)"
        case .switched(let quality): "switched to \(quality)"
        }
    }
}

/// Picks the engine configuration for an adaptive `Quality`. Used only from the pipeline queue; times are host clock
/// seconds.
///
/// Steps down after a window of frames whose p50 misses the budget. Steps up only after a trial: the higher step runs
/// on copies of the frames while the current step keeps producing output, so a busy GPU never shows as a stutter.
/// A trial starts only from a step that fits its budget, and failed trials back off from 20 s to 160 s. No step-down
/// happens while a trial runs, which takes about a second, and the window starts over after it because the trial
/// slows the running step.
final class AdaptiveController {
    static let budgetFraction = 0.65
    static let trialFraction = 0.9
    static let window = 1.5
    static let settleFrames = 3
    static let trialSettleFrames = 2
    static let trialFrames = 20
    static let trialTimeout = 5.0
    static let firstTrialDelay = 20.0
    static let maxTrialDelay = 160.0
    /// Falling back this soon after a trial passed counts as a failed trial.
    static let quickFallback = 30.0

    var onEvent: ((AdaptiveEvent) -> Void)?

    private struct Sample {
        var time: Double
        var inference: Double
        var total: Double
    }

    private struct Trial {
        var step: Int
        var started: Double
        var seen = 0
        var inference: [Double] = []
    }

    private var sizes: [ModelSize] = []
    private var conditions: SystemConditions
    private var preferred: Quality?
    private var steps: [Quality] = []
    private var step = 0
    private var reason = AdaptiveReason.preferred
    private var samples: [Sample] = []
    private var settled = 0
    private var stepStart: Double?
    private var trial: Trial?
    private var nextTrial = 0.0
    private var trialDelay = firstTrialDelay
    private var steppedUp: Double?
    private var lastArrival: CMTime?
    private var intervals: [Double] = []

    init(conditions: SystemConditions) {
        self.conditions = conditions
    }

    /// Nil unless the last quality asked for was adaptive.
    var decision: AdaptiveDecision? {
        preferred == nil ? nil : AdaptiveDecision(quality: steps[step], reason: reason)
    }

    var trialQuality: Quality? {
        trial.map { steps[$0.step] }
    }

    var fallback: Quality? {
        guard preferred != nil, step + 1 < steps.count else { return nil }
        return steps[step + 1]
    }

    /// The engine configuration to run for an adaptive `quality`, using the model `sizes`. `current` is the engine that
    /// ran last.
    func target(for quality: Quality, sizes: [ModelSize], current: Quality?, now: Double) -> Quality {
        if quality != preferred || sizes != self.sizes { start(quality, sizes: sizes, current: current, now: now) }
        return steps[step]
    }

    /// Returns whether it was adapting.
    func stop() -> Bool {
        defer {
            preferred = nil
            trial = nil
        }
        return preferred != nil
    }

    /// The preferred configuration, then its size on the Neural Engine, then each smaller size down to 480x270 on the
    /// Neural Engine, skipping sizes without a model.
    static func steps(for quality: Quality, available: [ModelSize]) -> [Quality] {
        var steps = [quality.fixed]
        if quality.mode != .ane { steps.append(Quality(size: quality.size, mode: .ane)) }
        steps += available
            .filter { $0.pixels < quality.size.pixels && $0.pixels >= ModelSize.size480x270.pixels }
            .sorted { $0.pixels > $1.pixels }
            .map { Quality(size: $0, mode: .ane) }
        let usable = steps.filter { available.contains($0.size) }
        return usable.isEmpty ? [quality.fixed] : usable
    }

    func recordArrival(_ time: CMTime) {
        defer { lastArrival = time }
        guard let lastArrival else { return }
        let seconds = (time - lastArrival).seconds
        guard seconds > 0, seconds < 0.5 else { return intervals.removeAll() }
        intervals.append(seconds)
        if intervals.count > 30 { intervals.removeFirst() }
    }

    /// A frame from `quality`'s engine reached the outputs.
    func recordFrame(on quality: Quality, inference: Double, total: Double, now: Double) {
        guard preferred != nil, quality == steps[step] else { return }
        if let trial, now - trial.started > Self.trialTimeout {
            endTrial()
            backOff(now)
        }
        settled += 1
        guard settled > Self.settleFrames else { return }
        if stepStart == nil { stepStart = now }
        samples.append(Sample(time: now, inference: inference, total: total))
        samples.removeAll { now - $0.time > Self.window }

        guard trial == nil, let interval = frameInterval, let stepStart, now - stepStart >= Self.window else { return }
        let milliseconds = median(samples.map(\.total))
        let budget = budget(for: quality, interval: interval)
        guard milliseconds > budget else { return startTrialIfDue(now, interval: interval) }
        guard step + 1 < steps.count else { return }
        if steppedUp.map({ now - $0 >= Self.quickFallback }) ?? true { trialDelay = Self.firstTrialDelay }
        backOff(now)
        steppedUp = nil
        move(to: step + 1, reason: .slowFrames(quality, milliseconds: milliseconds, budget: budget))
    }

    /// A trial frame on `quality`'s engine finished.
    func recordTrial(on quality: Quality, inference: Double, now: Double) {
        guard var trial, steps[trial.step] == quality else { return }
        trial.seen += 1
        if trial.seen > Self.trialSettleFrames { trial.inference.append(inference) }
        self.trial = trial
        guard trial.inference.count >= Self.trialFrames, let interval = frameInterval else { return }

        let overhead = samples.isEmpty ? 0 : max(0, median(samples.map(\.total)) - median(samples.map(\.inference)))
        let milliseconds = median(trial.inference) + overhead
        let limit = Self.trialFraction * budget(for: quality, interval: interval)
        if milliseconds <= limit {
            steppedUp = now
            nextTrial = now + trialDelay
            move(to: trial.step, reason: trial.step == 0 ? .preferred : .trialFit(milliseconds: milliseconds, limit: limit))
        } else {
            endTrial()
            backOff(now)
            setReason(.trialTooSlow(quality, milliseconds: milliseconds, limit: limit))
        }
    }

    /// Drops a configuration whose engine failed to load. Returns whether it was one of the steps.
    func engineFailed(_ quality: Quality) -> Bool {
        guard preferred != nil, steps.count > 1, let index = steps.firstIndex(of: quality) else { return false }
        steps.remove(at: index)
        if index == step {
            move(to: min(step, steps.count - 1), reason: .engineFailed(quality))
        } else if index < step {
            step -= 1
            if trial?.step == index {
                trial = nil
                setReason(.engineFailed(quality))
            } else {
                trial?.step -= 1
            }
        }
        return true
    }

    func update(_ conditions: SystemConditions, now: Double) {
        guard conditions != self.conditions else { return }
        let previousFloor = floor
        self.conditions = conditions
        guard preferred != nil else { return }
        if let trial, trial.step < floor { endTrial() }
        if step < floor, let reason = conditions.reason {
            move(to: floor, reason: reason)
        } else if floor < previousFloor {
            trialDelay = Self.firstTrialDelay
            nextTrial = now
            setReason(.pendingTrial)
        } else if step == floor, let reason = conditions.reason {
            setReason(reason)
        }
    }

    /// Keeps the running engine when it is one of the steps. Otherwise starts on the Neural Engine and tries the
    /// preferred configuration once that step fits its budget, so a busy GPU does not drop frames at startup.
    private func start(_ quality: Quality, sizes: [ModelSize], current: Quality?, now: Double) {
        preferred = quality
        self.sizes = sizes
        steps = Self.steps(for: quality, available: sizes)
        if let current, let index = steps.firstIndex(of: current), index >= floor {
            step = index
        } else {
            step = max(floor, steps.firstIndex { $0.mode == .ane } ?? 0)
        }
        reason = step == 0 ? .preferred : conditions.reason ?? .pendingTrial
        resetStep()
        trial = nil
        trialDelay = Self.firstTrialDelay
        nextTrial = now
        steppedUp = nil
        emitDecision()
    }

    /// The first Neural Engine step while the Mac is on battery, in Low Power Mode or hot.
    private var floor: Int {
        guard conditions.reason != nil else { return 0 }
        return steps.firstIndex { $0.mode == .ane } ?? 0
    }

    private var frameInterval: Double? {
        intervals.count < 5 ? nil : median(intervals)
    }

    private func budget(for quality: Quality, interval: Double) -> Double {
        Self.budgetFraction * interval * 1000 * (quality.mode == .dual ? 2 : 1)
    }

    /// A trial on the device that runs the current step waits until that device has time for both in a frame
    /// interval, or it would delay the output. Its time is estimated from the current step's by pixel count.
    private func startTrialIfDue(_ now: Double, interval: Double) {
        guard step > floor, now >= nextTrial else { return }
        let current = steps[step], next = steps[step - 1]
        if next.mode == current.mode {
            let inference = median(samples.map(\.inference))
            let expected = inference * Double(next.size.pixels) / Double(current.size.pixels)
            guard inference + expected <= interval * 1000 else { return }
        }
        trial = Trial(step: step - 1, started: now)
        onEvent?(.trialStarted(next))
    }

    private func endTrial() {
        trial = nil
        resetStep()
    }

    private func backOff(_ now: Double) {
        nextTrial = now + trialDelay
        trialDelay = min(trialDelay * 2, Self.maxTrialDelay)
    }

    private func move(to index: Int, reason: AdaptiveReason) {
        step = index
        self.reason = reason
        trial = nil
        resetStep()
        emitDecision()
    }

    private func setReason(_ reason: AdaptiveReason) {
        guard reason != self.reason else { return }
        self.reason = reason
        emitDecision()
    }

    private func resetStep() {
        samples.removeAll()
        settled = 0
        stepStart = nil
    }

    private func emitDecision() {
        if let decision { onEvent?(.decided(decision)) }
    }
}

private extension ModelSize {
    var pixels: Int { width * height }
}
