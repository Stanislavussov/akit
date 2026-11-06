import Foundation

/// The rows of the model Pickers (M10): which OpenRouter models take audio, what an hour costs,
/// which are recommended.
public enum ModelCatalog {
    /// Gemini counts 32 tokens per second of audio; one hour of talk is about 12,000 tokens of text.
    public static let audioTokensPerHour = 115_200.0
    public static let textTokensPerHour = 12_000.0

    public struct Row: Equatable, Sendable, Identifiable, Hashable {
        public var id: String
        public var name: String
        /// Estimated USD for one hour of audio (transcription), or for one hour's transcript
        /// (summary); nil when the price is not known.
        public var hourCost: Double?
        public var recommended: Bool

        public init(id: String, name: String, hourCost: Double?, recommended: Bool) {
            self.id = id
            self.name = name
            self.hourCost = hourCost
            self.recommended = recommended
        }
    }

    /// Models that take audio and write text, cheapest hour first, recommended ones first among
    /// equals. Router entries with negative prices are left out.
    public static func audioRows(_ models: [OpenRouterModel]) -> [Row] {
        models.compactMap { model -> Row? in
            let input = model.architecture?.input_modalities ?? []
            let output = model.architecture?.output_modalities ?? ["text"]
            guard input.contains("audio"), output.contains("text") else { return nil }
            guard let completion = price(model.pricing?.completion), let audio = price(model.pricing?.audio) ?? price(model.pricing?.prompt),
                  completion >= 0, audio >= 0 else { return nil }
            return Row(id: model.id, name: model.name ?? model.id,
                       hourCost: audio * audioTokensPerHour + completion * textTokensPerHour,
                       recommended: isRecommended(model.id))
        }
        .sorted(by: order)
    }

    /// Models that read and write text, for the summary: priced on one hour's transcript in and a
    /// page out.
    public static func textRows(_ models: [OpenRouterModel]) -> [Row] {
        models.compactMap { model -> Row? in
            let input = model.architecture?.input_modalities ?? ["text"]
            let output = model.architecture?.output_modalities ?? ["text"]
            guard input.contains("text"), output.contains("text") else { return nil }
            guard let prompt = price(model.pricing?.prompt), let completion = price(model.pricing?.completion),
                  prompt >= 0, completion >= 0 else { return nil }
            return Row(id: model.id, name: model.name ?? model.id,
                       hourCost: prompt * textTokensPerHour + completion * 1_500,
                       recommended: isRecommended(model.id))
        }
        .sorted(by: order)
    }

    /// The Gemini Flash-Lite family: cheap and good at Czech. Batch variants are slower and are
    /// not marked.
    public static func isRecommended(_ id: String) -> Bool {
        id.hasPrefix("google/gemini-") && id.contains("flash-lite") && !id.contains(":") && !id.contains("preview")
    }

    static func price(_ text: String?) -> Double? { text.flatMap(Double.init) }

    static func order(_ a: Row, _ b: Row) -> Bool {
        let (x, y) = (a.hourCost ?? .infinity, b.hourCost ?? .infinity)
        if x != y { return x < y }
        if a.recommended != b.recommended { return a.recommended }
        return a.id < b.id
    }

    /// `$0.04/h`, `$0.145/h`.
    public static func priceText(_ cost: Double?) -> String {
        guard let cost else { return "price unknown" }
        if cost == 0 { return "free" }
        return cost < 0.1 ? String(format: "$%.3f/h", cost) : String(format: "$%.2f/h", cost)
    }
}
