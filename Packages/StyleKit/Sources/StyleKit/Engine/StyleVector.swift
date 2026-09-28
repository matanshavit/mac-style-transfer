/// The 100-number Magenta style bottleneck.
public struct StyleVector: Hashable, Sendable, Codable {
    public static let dimension = 100

    public let values: [Float]

    public init(_ values: [Float]) {
        precondition(values.count == Self.dimension, "a style vector has \(Self.dimension) values, got \(values.count)")
        self.values = values
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.singleValueContainer().decode([Float].self)
        guard values.count == Self.dimension else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "expected \(Self.dimension) values"))
        }
        self.values = values
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }

    public var norm: Float {
        values.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    /// Magenta style strength: `strength * self + (1 - strength) * content`.
    public func blended(withContent content: StyleVector, strength: Float) -> StyleVector {
        StyleVector(zip(values, content.values).map { strength * $0 + (1 - strength) * $1 })
    }
}
