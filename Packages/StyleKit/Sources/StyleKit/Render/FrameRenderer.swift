import CoreVideo
import Metal
import MetalPerformanceShaders

private struct BlendUniforms {
    var staticWeight: Float
    var motionLow: Float
    var motionHigh: Float
    var resetThreshold: Float
    var reset: UInt32
    var pixelCount: UInt32
}

private struct GuidedUniforms {
    var radius: Int32
    var epsilon: Float
    var maxCoefficient: Float
}

private struct CompositeUniforms {
    var cameraOrigin: SIMD2<Float>
    var cameraScale: SIMD2<Float>
    var outputSize: SIMD2<Float>
    var detail: Float
    var feather: Float
    var guided: UInt32
    var preserveColors: UInt32
    var maskMode: UInt32
    var hasMask: UInt32
}

struct PostOptions {
    var smoothing: Float
    var upsampling: UpsamplingMode
    var detail: Float
    var preserveColors: Bool
    var mask: MaskMode
    var resetHistory: Bool
}

/// Encodes all GPU work. Used only from the pipeline queue: the temporal history is shared state between frames.
final class FrameRenderer {
    static let motionLow: Float = 0.01
    static let motionHigh: Float = 0.05
    static let cutThreshold: Float = 0.15
    static let guidedRadius: Int32 = 2
    static let guidedEpsilon: Float = 4e-4
    static let maxGuidedCoefficient: Float = 2
    static let maskFeatherPixels: Float = 4

    let context: MetalContext
    let outputWidth: Int
    let outputHeight: Int

    private final class History {
        let width: Int
        let height: Int
        let luma: [any MTLTexture]
        let smoothed: [any MTLTexture]
        let motion: any MTLTexture
        let coefficients: any MTLTexture
        let meanCoefficients: any MTLTexture
        var current = 0
        var valid = false

        init(context: MetalContext, width: Int, height: Int) {
            self.width = width
            self.height = height
            luma = (0..<2).map { _ in context.makeTexture(width: width, height: height, format: .r16Float) }
            smoothed = (0..<2).map { _ in context.makeTexture(width: width, height: height, format: .rgba16Float) }
            motion = context.makeTexture(width: width, height: height, format: .r16Float)
            coefficients = context.makeTexture(width: width, height: height, format: .rgba16Float)
            meanCoefficients = context.makeTexture(width: width, height: height, format: .rgba16Float)
        }
    }

    private let outputPool: PixelBufferPool
    private let downscaler: MPSImageLanczosScale
    private let motionPipeline: any MTLComputePipelineState
    private let blendPipeline: any MTLComputePipelineState
    private let coefficientPipeline: any MTLComputePipelineState
    private let boxPipeline: any MTLComputePipelineState
    private let compositePipeline: any MTLComputePipelineState
    private let bypassPipeline: any MTLComputePipelineState
    private let placeholder: any MTLTexture
    private let motionSums: [any MTLBuffer]
    private var motionSumIndex = 0
    private var history: History?

    init(context: MetalContext, outputWidth: Int, outputHeight: Int) throws {
        self.context = context
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        outputPool = try PixelBufferPool(width: outputWidth, height: outputHeight,
                                         pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, minimumBufferCount: 4)
        downscaler = MPSImageLanczosScale(device: context.device)
        motionPipeline = try context.pipeline("motion_luma")
        blendPipeline = try context.pipeline("temporal_blend")
        coefficientPipeline = try context.pipeline("guided_coefficients")
        boxPipeline = try context.pipeline("box_filter")
        compositePipeline = try context.pipeline("composite_nv12")
        bypassPipeline = try context.pipeline("camera_nv12")
        placeholder = context.makeTexture(width: 1, height: 1, format: .r8Unorm)
        motionSums = (0..<4).map { _ in context.device.makeBuffer(length: 4, options: .storageModeShared)! }
    }

    func resetHistory() {
        history?.valid = false
    }

    /// Scales the camera frame (aspect fill) into the model input and, when given, the style predictor input.
    func encodeDownscale(camera: CVPixelBuffer, into input: CVPixelBuffer, predictorInput: CVPixelBuffer?,
                         commandBuffer: any MTLCommandBuffer) throws -> [CVMetalTexture] {
        let source = try context.texture(for: camera, format: .bgra8Unorm)
        var owners = [source.owner]
        for destination in [input, predictorInput].compactMap({ $0 }) {
            let target = try context.texture(for: destination, format: .bgra8Unorm)
            owners.append(target.owner)
            var transform = Self.aspectFill(from: camera, toWidth: destination.width, height: destination.height)
            withUnsafePointer(to: &transform) { pointer in
                downscaler.scaleTransform = pointer
                downscaler.encode(commandBuffer: commandBuffer, sourceTexture: source.texture, destinationTexture: target.texture)
                downscaler.scaleTransform = nil
            }
        }
        return owners
    }

    /// Smoothing, upsampling, compositing and NV12 conversion in one encoder. Returns the output and the textures the
    /// command buffer must keep alive.
    func encodeStylized(camera: CVPixelBuffer, input: CVPixelBuffer, stylized: CVPixelBuffer, mask: (any MTLTexture)?,
                        options: PostOptions, commandBuffer: any MTLCommandBuffer) throws -> (CVPixelBuffer, [CVMetalTexture]) {
        let history = history(width: stylized.width, height: stylized.height)
        let cameraTexture = try context.texture(for: camera, format: .bgra8Unorm)
        let inputTexture = try context.texture(for: input, format: .bgra8Unorm)
        let stylizedTexture = try context.texture(for: stylized, format: .bgra8Unorm)
        let (output, lumaPlane, chromaPlane) = try makeOutput()

        let previous = history.current, current = 1 - history.current
        let motionSum = motionSums[motionSumIndex]
        motionSumIndex = (motionSumIndex + 1) % motionSums.count
        motionSum.contents().storeBytes(of: 0, as: UInt32.self)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalError.commandBuffer }
        encoder.setTexture(inputTexture.texture, index: 0)
        encoder.setTexture(history.luma[previous], index: 1)
        encoder.setTexture(history.luma[current], index: 2)
        encoder.setTexture(history.motion, index: 3)
        encoder.setBuffer(motionSum, offset: 0, index: 0)
        encoder.dispatch(motionPipeline, width: history.width, height: history.height)

        var blend = BlendUniforms(
            staticWeight: 1 - 0.92 * min(max(options.smoothing, 0), 1),
            motionLow: Self.motionLow, motionHigh: Self.motionHigh, resetThreshold: Self.cutThreshold,
            reset: options.resetHistory || !history.valid ? 1 : 0, pixelCount: UInt32(history.width * history.height))
        encoder.setTexture(stylizedTexture.texture, index: 0)
        encoder.setTexture(history.smoothed[previous], index: 1)
        encoder.setTexture(history.motion, index: 2)
        encoder.setTexture(history.smoothed[current], index: 3)
        encoder.setBytes(&blend, length: MemoryLayout<BlendUniforms>.stride, index: 0)
        encoder.setBuffer(motionSum, offset: 0, index: 1)
        encoder.dispatch(blendPipeline, width: history.width, height: history.height)

        let guided = options.upsampling == .guided && options.detail > 0
        if guided {
            var uniforms = GuidedUniforms(radius: Self.guidedRadius, epsilon: Self.guidedEpsilon, maxCoefficient: Self.maxGuidedCoefficient)
            encoder.setTexture(history.luma[current], index: 0)
            encoder.setTexture(history.smoothed[current], index: 1)
            encoder.setTexture(history.coefficients, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<GuidedUniforms>.stride, index: 0)
            encoder.dispatch(coefficientPipeline, width: history.width, height: history.height)
            encoder.setTexture(history.coefficients, index: 0)
            encoder.setTexture(history.meanCoefficients, index: 1)
            encoder.dispatch(boxPipeline, width: history.width, height: history.height)
        }

        let maskTexture = options.mask == .everything ? nil : mask
        var composite = compositeUniforms(camera: camera)
        composite.detail = options.detail
        composite.guided = guided ? 1 : 0
        composite.preserveColors = options.preserveColors ? 1 : 0
        composite.maskMode = switch options.mask {
        case .everything: 0
        case .backgroundOnly: 1
        case .personOnly: 2
        }
        composite.hasMask = maskTexture == nil ? 0 : 1
        encoder.setTexture(cameraTexture.texture, index: 0)
        encoder.setTexture(history.smoothed[current], index: 1)
        encoder.setTexture(history.luma[current], index: 2)
        encoder.setTexture(guided ? history.meanCoefficients : placeholder, index: 3)
        encoder.setTexture(maskTexture ?? placeholder, index: 4)
        encoder.setTexture(lumaPlane.texture, index: 5)
        encoder.setTexture(chromaPlane.texture, index: 6)
        encoder.setBytes(&composite, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.dispatch(compositePipeline, width: outputWidth / 2, height: outputHeight / 2)
        encoder.endEncoding()

        history.current = current
        history.valid = true
        let owners = [cameraTexture.owner, inputTexture.owner, stylizedTexture.owner, lumaPlane.owner, chromaPlane.owner]
        return (output, owners)
    }

    func encodeBypass(camera: CVPixelBuffer, commandBuffer: any MTLCommandBuffer) throws -> (CVPixelBuffer, [CVMetalTexture]) {
        let cameraTexture = try context.texture(for: camera, format: .bgra8Unorm)
        let (output, lumaPlane, chromaPlane) = try makeOutput()
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalError.commandBuffer }
        var uniforms = compositeUniforms(camera: camera)
        encoder.setTexture(cameraTexture.texture, index: 0)
        encoder.setTexture(lumaPlane.texture, index: 5)
        encoder.setTexture(chromaPlane.texture, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
        encoder.dispatch(bypassPipeline, width: outputWidth / 2, height: outputHeight / 2)
        encoder.endEncoding()
        return (output, [cameraTexture.owner, lumaPlane.owner, chromaPlane.owner])
    }

    private func history(width: Int, height: Int) -> History {
        if let history, history.width == width, history.height == height { return history }
        let created = History(context: context, width: width, height: height)
        history = created
        return created
    }

    private func makeOutput() throws -> (CVPixelBuffer, BufferTexture, BufferTexture) {
        let output = try outputPool.make()
        NV12Attachments.apply(to: output)
        let luma = try context.texture(for: output, plane: 0, format: .r8Unorm)
        let chroma = try context.texture(for: output, plane: 1, format: .rg8Unorm)
        return (output, luma, chroma)
    }

    /// Normalized camera region that fills the output aspect.
    private func compositeUniforms(camera: CVPixelBuffer) -> CompositeUniforms {
        let cameraAspect = Float(camera.width) / Float(camera.height)
        let outputAspect = Float(outputWidth) / Float(outputHeight)
        let scale = cameraAspect > outputAspect
            ? SIMD2<Float>(outputAspect / cameraAspect, 1)
            : SIMD2<Float>(1, cameraAspect / outputAspect)
        return CompositeUniforms(cameraOrigin: (1 - scale) / 2, cameraScale: scale,
                                 outputSize: SIMD2(Float(outputWidth), Float(outputHeight)), detail: 0,
                                 feather: Self.maskFeatherPixels, guided: 0, preserveColors: 0, maskMode: 0, hasMask: 0)
    }

    private static func aspectFill(from camera: CVPixelBuffer, toWidth width: Int, height: Int) -> MPSScaleTransform {
        let scale = max(Double(width) / Double(camera.width), Double(height) / Double(camera.height))
        return MPSScaleTransform(scaleX: scale, scaleY: scale,
                                 translateX: (Double(width) - Double(camera.width) * scale) / 2,
                                 translateY: (Double(height) - Double(camera.height) * scale) / 2)
    }
}
