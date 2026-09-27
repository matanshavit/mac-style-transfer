import Accelerate
import CoreGraphics
import CoreML
import CoreVideo
import Foundation

public enum StylePredictorError: Error, CustomStringConvertible {
    case unexpectedModel(String)
    case imageConversion

    public var description: String {
        switch self {
        case .unexpectedModel(let detail): "unexpected predictor model: \(detail)"
        case .imageConversion: "could not convert the image for the style predictor"
        }
    }
}

public final class StylePredictor: @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()
    private let inputName: String
    private let outputName: String
    private let fixedSize: ModelSize?
    private let allowedSizes: Set<ModelSize>

    public static func load(from store: ModelStore, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) async throws -> StylePredictor {
        try StylePredictor(model: await store.loadModel(named: ModelStore.predictorNames, computeUnits: computeUnits))
    }

    public init(model: MLModel) throws {
        let description = model.modelDescription
        guard let input = description.inputDescriptionsByName.values.first(where: { $0.imageConstraint != nil }),
              let constraint = input.imageConstraint else {
            throw StylePredictorError.unexpectedModel("no image input")
        }
        guard let output = description.outputDescriptionsByName.values.first(where: { $0.multiArrayConstraint != nil }) else {
            throw StylePredictorError.unexpectedModel("no multiarray output")
        }
        self.model = model
        inputName = input.name
        outputName = output.name
        let sizes = constraint.sizeConstraint.enumeratedImageSizes.map { ModelSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
        allowedSizes = Set(sizes)
        fixedSize = constraint.sizeConstraint.type == .unspecified
            ? ModelSize(width: constraint.pixelsWide, height: constraint.pixelsHigh)
            : nil
    }

    /// Height 256 keeping aspect, width rounded to the nearest multiple of 32 and clamped to 128...512.
    public func inputSize(forWidth width: Int, height: Int) -> ModelSize {
        if let fixedSize { return fixedSize }
        let scaled = Double(width) * 256 / Double(max(height, 1))
        let rounded = min(512, max(128, Int((scaled / 32).rounded()) * 32))
        let size = ModelSize(width: rounded, height: 256)
        if allowedSizes.isEmpty || allowedSizes.contains(size) { return size }
        return allowedSizes.filter { $0.height == 256 }.min { abs($0.width - rounded) < abs($1.width - rounded) } ?? size
    }

    public func vector(for image: CGImage) throws -> StyleVector {
        let size = inputSize(forWidth: image.width, height: image.height)
        let buffer = try Self.makeBuffer(size)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: size.width, height: size.height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw StylePredictorError.imageConversion }
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return try predict(buffer)
    }

    /// Accepts a BGRA buffer of any size; buffers already at `inputSize` are used without a copy.
    public func vector(for pixelBuffer: CVPixelBuffer) throws -> StyleVector {
        let size = inputSize(forWidth: pixelBuffer.width, height: pixelBuffer.height)
        if pixelBuffer.width == size.width && pixelBuffer.height == size.height {
            return try predict(pixelBuffer)
        }
        let scaled = try Self.makeBuffer(size)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(scaled, [])
        defer {
            CVPixelBufferUnlockBaseAddress(scaled, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        var source = vImage_Buffer(data: CVPixelBufferGetBaseAddress(pixelBuffer), height: vImagePixelCount(pixelBuffer.height),
                                   width: vImagePixelCount(pixelBuffer.width), rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer))
        var destination = vImage_Buffer(data: CVPixelBufferGetBaseAddress(scaled), height: vImagePixelCount(size.height),
                                        width: vImagePixelCount(size.width), rowBytes: CVPixelBufferGetBytesPerRow(scaled))
        guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else {
            throw StylePredictorError.imageConversion
        }
        return try predict(scaled)
    }

    private func predict(_ buffer: CVPixelBuffer) throws -> StyleVector {
        let features = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: buffer)])
        let result = try lock.withLock { try model.prediction(from: features) }
        guard let array = result.featureValue(for: outputName)?.multiArrayValue, array.count == StyleVector.dimension else {
            throw StylePredictorError.unexpectedModel("bottleneck output is not \(StyleVector.dimension) values")
        }
        let axis = array.shape.firstIndex { $0.intValue == StyleVector.dimension } ?? 0
        return StyleVector((0..<StyleVector.dimension).map { i in
            var index = [NSNumber](repeating: 0, count: array.shape.count)
            index[axis] = NSNumber(value: i)
            return array[index].floatValue
        })
    }

    static func makeBuffer(_ size: ModelSize) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]() as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw PixelBufferError.allocation(status) }
        return buffer
    }
}
