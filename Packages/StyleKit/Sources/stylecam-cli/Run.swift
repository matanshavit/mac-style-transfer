import AVFoundation
import Foundation
import StyleKit

func runPipeline(_ arguments: Arguments) async throws {
    let store = ModelStore(directory: try arguments.url("models"))
    let predictor = try await StylePredictor.load(from: store)
    let library = try StyleLibrary(catalogDirectory: try arguments.url("styles"), predictor: predictor)
    let styleName = try arguments.required("style")
    let style: StyleVector
    if await library.style(id: styleName) != nil {
        style = try await library.vector(for: styleName)
    } else if FileManager.default.fileExists(atPath: styleName) {
        style = try predictor.vector(for: StyleLibrary.loadImage(at: URL(fileURLWithPath: styleName)))
    } else {
        throw UsageError(description: "--style \(styleName) is neither a catalog id nor an image file")
    }

    var settings = PipelineSettings(style: style)
    settings.quality = try arguments.choice("quality", as: QualityPreset.self)?.quality ?? .balanced
    if let size = arguments.string("size") {
        guard let parsed = ModelSize(size) else { throw UsageError(description: "--size expects WxH") }
        settings.quality.size = parsed
    }
    if let mode = try arguments.choice("mode", as: EngineMode.self) { settings.quality.mode = mode }
    settings.strength = try arguments.float("strength") ?? settings.strength
    settings.smoothing = try arguments.float("smoothing") ?? settings.smoothing
    settings.upsampling = try arguments.choice("upsample", as: UpsamplingMode.self) ?? settings.upsampling
    settings.detail = try arguments.float("detail") ?? settings.detail
    settings.preserveColors = arguments.flag("preserve-colors")
    settings.mask = try arguments.choice("mask", as: MaskMode.self) ?? settings.mask
    settings.segmentationQuality = try arguments.choice("segmentation", as: SegmentationQuality.self) ?? settings.segmentationQuality
    let realtime = arguments.flag("realtime")
    let codec: AVVideoCodecType = arguments.string("codec") == "hevc" ? .hevc : .h264
    let loops = arguments.flag("loop")
    let maxFrames = try arguments.int("frames")
    if loops && maxFrames == nil { throw UsageError(description: "--loop needs --frames") }

    let source = try Y4MFileSource(url: try arguments.url("input"), frameRate: Double(try arguments.int("fps") ?? 30),
                                   pacing: realtime ? .realtime : .asFastAsPossible, maxFrames: maxFrames, loops: loops)
    let pipeline = try StylePipeline(modelStore: store, settings: settings, backpressure: realtime ? .dropFrames : .waitForSlot)
    if arguments.flag("log-adaptive") { logAdaptation(of: pipeline) }
    try await pipeline.prepare()

    let expected = source.outputFrameCount ?? 0
    let stills = try arguments.string("still-frames").map { list in
        try Set(list.split(separator: ",").map { item in
            guard let index = Int(item) else { throw UsageError(description: "--still-frames expects a,b,c") }
            return index
        })
    } ?? [expected / 6, expected / 2, expected * 5 / 6]
    let analyzer = try FrameAnalyzer(stillsDirectory: arguments.string("stills").map { URL(fileURLWithPath: $0) }, stillIndices: stills)
    let outputURL = try arguments.url("out")
    let writer = try VideoFileWriter(url: outputURL, width: pipeline.outputWidth, height: pipeline.outputHeight, codec: codec,
                                     realtime: realtime)
    pipeline.addOutput(writer)
    pipeline.onFrame = { analyzer.add($0) }

    print("input   \(source.url.lastPathComponent) \(source.width)x\(source.height) @ \(format(source.fileFrameRate, 0)) fps, "
        + "every \(source.frameStep) frame(s) -> \(format(source.frameRate, 1)) fps, \(realtime ? "realtime" : "as fast as possible")")
    print("style   \(styleName) strength \(settings.strength) | \(settings.quality) | smoothing \(settings.smoothing) | "
        + "\(settings.upsampling.rawValue) detail \(settings.detail) | preserve colors \(settings.preserveColors) | "
        + "mask \(settings.mask.rawValue)")

    let start = now()
    await withCheckedContinuation { continuation in
        source.start(handler: pipeline.frameHandler) { continuation.resume() }
    }
    await pipeline.waitUntilIdle()
    let seconds = now() - start
    try await writer.finish()
    let report = await analyzer.finish()
    let dropped = source.emittedFrames - report.frames

    print("frames  \(report.frames) out (\(report.stylized) stylized), \(dropped) dropped, \(source.skippedFrames) skipped by source pacing")
    print("fps     \(format(Double(report.frames) / seconds, 1)) sustained over \(format(seconds, 2)) s, output interval "
        + "p50 \(format(percentile(report.outputIntervals, 0.5))) p95 \(format(percentile(report.outputIntervals, 0.95))) "
        + "max \(format(report.outputIntervals.max() ?? 0)) ms")
    let rows: [(String, KeyPath<FrameTimings, Double>)] = [
        ("downscale (gpu)", \.downscaleMilliseconds), ("inference", \.inferenceMilliseconds),
        ("post (gpu)", \.postMilliseconds), ("total", \.totalMilliseconds), ("latency", \.latencyMilliseconds),
    ]
    print("stage ms          p50     mean    p95")
    for (name, path) in rows {
        let values = report.timings.map { $0[keyPath: path] }
        print(name.padding(toLength: 16, withPad: " ", startingAt: 0)
            + [percentile(values, 0.5), mean(values), percentile(values, 0.95)].map { format($0).leftPadded(8) }.joined())
    }
    let byDevice = Dictionary(grouping: report.timings.filter { $0.device != nil }, by: { $0.device! })
    print("devices " + byDevice.sorted { $0.key.rawValue > $1.key.rawValue }.map { device, timings in
        let inference = timings.map(\.inferenceMilliseconds)
        return "\(device.rawValue) \(timings.count) frames, inference p50 \(format(percentile(inference, 0.5))) "
            + "p95 \(format(percentile(inference, 0.95))) ms"
    }.joined(separator: "; "))
    print("static  flicker \(format(report.staticFlicker, 3)) levels over \(format(report.staticFraction * 100, 1))% of pixels")
    print("moving  output change \(format(report.movingOutputChange, 2)) / input \(format(report.movingInputChange, 2)) levels "
        + "over \(format(report.movingFraction * 100, 1))% of pixels")
    print("wrote   \(outputURL.path) (\(writer.framesWritten) frames)")
    for still in report.stills.sorted(by: { $0.path < $1.path }) { print("still   \(still.path)") }
}

private func logAdaptation(of pipeline: StylePipeline) {
    let start = now()
    let stamp: @Sendable () -> String = { "[\(format(now() - start, 2).leftPadded(7)) s]" }
    pipeline.onAdaptiveEvent = { event in print("\(stamp()) \(event)") }
    pipeline.onStats = { stats in
        print("\(stamp()) \(stats.engine ?? "passthrough") | \(format(stats.outputFPS, 1)) fps | inference p50 "
            + "\(format(stats.inferenceMillisecondsP50, 1)) ms | latency p50 \(format(stats.latencyMillisecondsP50, 1)) ms | "
            + "dropped \(stats.droppedFrames) (\(stats.totalDroppedFrames) total)" + (stats.lastError.map { " | error \($0)" } ?? ""))
    }
}

private extension String {
    func leftPadded(_ width: Int) -> String {
        String(repeating: " ", count: max(0, width - count)) + self
    }
}
