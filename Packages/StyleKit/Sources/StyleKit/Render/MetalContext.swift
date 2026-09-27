import CoreVideo
import Metal

public enum MetalError: Error, CustomStringConvertible {
    case noDevice
    case missingFunction(String)
    case commandBuffer

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .missingFunction(let name): "shader function \(name) is missing"
        case .commandBuffer: "could not create a Metal command buffer"
        }
    }
}

/// A Metal texture view of a pixel buffer plane. `owner` must stay alive until the GPU is done with `texture`.
struct BufferTexture {
    let texture: any MTLTexture
    let owner: CVMetalTexture
}

final class MetalContext: @unchecked Sendable {
    let device: any MTLDevice
    let commandQueue: any MTLCommandQueue
    private let library: any MTLLibrary
    private let textureCache: CVMetalTextureCache

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw MetalError.noDevice }
        self.device = device
        commandQueue = queue
        library = try device.makeLibrary(source: shaderSource, options: nil)
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw PixelBufferError.textureCreation(status) }
        textureCache = cache
    }

    func pipeline(_ name: String) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else { throw MetalError.missingFunction(name) }
        return try device.makeComputePipelineState(function: function)
    }

    func makeCommandBuffer() throws -> any MTLCommandBuffer {
        guard let buffer = commandQueue.makeCommandBuffer() else { throw MetalError.commandBuffer }
        return buffer
    }

    func texture(for buffer: CVPixelBuffer, plane: Int = 0, format: MTLPixelFormat) throws -> BufferTexture {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : buffer.width
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : buffer.height
        let attributes = [kCVMetalTextureUsage: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        var owner: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, attributes, format, width, height, plane, &owner)
        guard status == kCVReturnSuccess, let owner, let texture = CVMetalTextureGetTexture(owner) else {
            throw PixelBufferError.textureCreation(status)
        }
        return BufferTexture(texture: texture, owner: owner)
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)!
    }
}

extension MTLComputeCommandEncoder {
    func dispatch(_ pipeline: any MTLComputePipelineState, width: Int, height: Int) {
        setComputePipelineState(pipeline)
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth / 2)
        dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1))
    }
}
