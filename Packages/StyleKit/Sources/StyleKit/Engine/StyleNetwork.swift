/// The style transformer. Both take the same inputs and give the same output.
public enum StyleNetwork: String, Sendable, CaseIterable, Identifiable {
    /// The Magenta arbitrary style transformer.
    case classic
    /// The Magenta transformer, anti-aliased and fine-tuned for temporal stability: less flicker on still areas and
    /// less texture change when the image moves, slightly smoother fine texture, and a little slower.
    case steady

    public var id: String { rawValue }

    /// Models are named `<prefix>_<W>x<H>`.
    public var modelPrefix: String {
        switch self {
        case .classic: "MagentaTransformer"
        case .steady: "StableTransformer"
        }
    }
}
