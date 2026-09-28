import CoreML
import CoreVideo
import Foundation

public enum ComputeDevice: String, Sendable {
    case gpu
    case ane
}

public enum StyleEngineError: Error, CustomStringConvertible {
    case unexpectedModel(String)
    case noOutput

    public var description: String {
        switch self {
        case .unexpectedModel(let detail): "unexpected transformer model: \(detail)"
        case .noOutput: "the transformer returned no image"
        }
    }
}

public struct StylizedFrame: @unchecked Sendable {
    /// BGRA at the model size, from the engine's output pool.
    public let pixelBuffer: CVPixelBuffer
    public let device: ComputeDevice
    public let inferenceMilliseconds: Double
}

/// Runs a style transformer. In dual mode frames go to whichever instance is free (GPU first), and results are
/// always delivered in submission order.
public final class StyleEngine: @unchecked Sendable {
    public typealias Completion = @Sendable (Result<StylizedFrame, any Error>) -> Void

    public let network: StyleNetwork
    public let size: ModelSize
    public let mode: EngineMode

    public var maxConcurrentFrames: Int { instances.count }
    var quality: Quality { Quality(size: size, mode: mode) }

    private final class Instance: @unchecked Sendable {
        let device: ComputeDevice
        let model: MLModel
        let queue: DispatchQueue
        var busy = false

        init(device: ComputeDevice, model: MLModel) {
            self.device = device
            self.model = model
            queue = DispatchQueue(label: "StyleKit.StyleEngine.\(device.rawValue)", qos: .userInteractive)
        }
    }

    private struct Request {
        let sequence: Int
        let content: CVPixelBuffer
        let style: MLMultiArray
        let completion: Completion
    }

    private let instances: [Instance]
    private let contentName: String
    private let styleName: String
    private let outputName: String
    private let inputPool: PixelBufferPool
    private let outputPool: PixelBufferPool
    private let control = DispatchQueue(label: "StyleKit.StyleEngine.control", qos: .userInteractive)
    private var pending: [Request] = []
    private var finished: [Int: (Completion, Result<StylizedFrame, any Error>)] = [:]
    private var nextSequence = 0
    private var nextDelivery = 0
    private var cachedStyle: (vector: StyleVector, array: MLMultiArray)?

    public static func load(store: ModelStore, network: StyleNetwork, size: ModelSize,
                            mode: EngineMode) async throws -> StyleEngine {
        let name = ModelStore.transformerName(for: network, size: size)
        var instances: [Instance] = []
        if mode != .ane {
            let model = try await store.loadModel(named: name, computeUnits: .cpuAndGPU, lowPrecisionAccumulationOnGPU: true)
            instances.append(Instance(device: .gpu, model: model))
        }
        if mode != .gpu {
            let model = try await store.loadModel(named: name, computeUnits: .cpuAndNeuralEngine)
            instances.append(Instance(device: .ane, model: model))
        }
        let engine = try StyleEngine(network: network, size: size, mode: mode, instances: instances)
        try await engine.warmUp()
        return engine
    }

    private init(network: StyleNetwork, size: ModelSize, mode: EngineMode, instances: [Instance]) throws {
        let description = instances[0].model.modelDescription
        guard let content = description.inputDescriptionsByName.values.first(where: { $0.imageConstraint != nil }),
              let style = description.inputDescriptionsByName.values.first(where: { $0.multiArrayConstraint != nil }),
              let output = description.outputDescriptionsByName.values.first(where: { $0.imageConstraint != nil }) else {
            throw StyleEngineError.unexpectedModel("expected an image and a multiarray input and an image output")
        }
        guard let constraint = content.imageConstraint, constraint.pixelsWide == size.width, constraint.pixelsHigh == size.height else {
            throw StyleEngineError.unexpectedModel("content input is not \(size)")
        }
        self.network = network
        self.size = size
        self.mode = mode
        self.instances = instances
        contentName = content.name
        styleName = style.name
        outputName = output.name
        inputPool = try PixelBufferPool(width: size.width, height: size.height, pixelFormat: kCVPixelFormatType_32BGRA)
        outputPool = try PixelBufferPool(width: size.width, height: size.height, pixelFormat: kCVPixelFormatType_32BGRA,
                                         minimumBufferCount: instances.count + 2)
    }

    /// A BGRA IOSurface buffer at the model size to render content into.
    public func makeInputBuffer() throws -> CVPixelBuffer {
        try inputPool.make()
    }

    /// `completion` runs on an internal serial queue, in submission order; keep it short.
    public func stylize(_ content: CVPixelBuffer, style: StyleVector, completion: @escaping Completion) {
        let box = UncheckedBox(content)
        control.async { [self] in
            let request = Request(sequence: nextSequence, content: box.value, style: styleArray(style), completion: completion)
            nextSequence += 1
            pending.append(request)
            dispatchPending()
        }
    }

    private func dispatchPending() {
        while !pending.isEmpty, let instance = instances.first(where: { !$0.busy }) {
            let request = pending.removeFirst()
            instance.busy = true
            let backing = Result { try outputPool.make() }
            let work = UncheckedBox((request, backing))
            instance.queue.async { [self] in
                let (request, backing) = work.value
                let start = HostClock.now()
                let result = Result {
                    let stylized = try predict(instance, content: request.content, style: request.style, backing: backing.get())
                    return StylizedFrame(pixelBuffer: stylized, device: instance.device,
                                         inferenceMilliseconds: HostClock.milliseconds(since: start))
                }
                let sequence = request.sequence, completion = request.completion
                control.async { [self] in
                    instance.busy = false
                    finished[sequence] = (completion, result)
                    deliverInOrder()
                    dispatchPending()
                }
            }
        }
    }

    private func deliverInOrder() {
        while let (completion, result) = finished.removeValue(forKey: nextDelivery) {
            nextDelivery += 1
            completion(result)
        }
    }

    private func predict(_ instance: Instance, content: CVPixelBuffer, style: MLMultiArray, backing: CVPixelBuffer) throws -> CVPixelBuffer {
        let features = try MLDictionaryFeatureProvider(dictionary: [
            contentName: MLFeatureValue(pixelBuffer: content),
            styleName: MLFeatureValue(multiArray: style),
        ])
        let options = MLPredictionOptions()
        options.outputBackings = [outputName: backing]
        let output = try instance.model.prediction(from: features, options: options)
        guard let image = output.featureValue(for: outputName)?.imageBufferValue else { throw StyleEngineError.noOutput }
        return image
    }

    private func styleArray(_ vector: StyleVector) -> MLMultiArray {
        if let cachedStyle, cachedStyle.vector == vector { return cachedStyle.array }
        let array = Self.makeStyleArray(vector)
        cachedStyle = (vector, array)
        return array
    }

    private static func makeStyleArray(_ vector: StyleVector) -> MLMultiArray {
        let shape: [NSNumber] = [1, NSNumber(value: StyleVector.dimension), 1, 1]
        let array = try! MLMultiArray(shape: shape, dataType: .float32)
        array.withUnsafeMutableBufferPointer(ofType: Float.self) { pointer, strides in
            for (i, value) in vector.values.enumerated() { pointer[i * strides[1]] = value }
        }
        return array
    }

    private func warmUp() async throws {
        let content = try makeInputBuffer()
        let style = Self.makeStyleArray(StyleVector(Array(repeating: 0, count: StyleVector.dimension)))
        for instance in instances {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let work = UncheckedBox((content, style))
                instance.queue.async { [self] in
                    continuation.resume(with: Result {
                        _ = try predict(instance, content: work.value.0, style: work.value.1, backing: outputPool.make())
                    })
                }
            }
        }
    }
}

/// Moves a non-Sendable value to another queue that becomes its only user.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
