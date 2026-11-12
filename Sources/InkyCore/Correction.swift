import Foundation

/// Kind of suggestion, Grammarly-style. Each gets its own color in the UI.
public enum EditCategory: String, Codable, CaseIterable, Sendable {
    case correctness, clarity, engagement, tone
}

/// A single change proposed by the model.
public struct Edit: Codable, Equatable, Sendable {
    public var original: String
    public var replacement: String
    public var explanation: String
    /// Raw value from the model; unknown values are ignored (see `kind`).
    public var category: String?

    public var kind: EditCategory { category.flatMap(EditCategory.init(rawValue:)) ?? .correctness }

    public init(original: String, replacement: String, explanation: String, category: String? = nil) {
        self.original = original
        self.replacement = replacement
        self.explanation = explanation
        self.category = category
    }
}

/// The model's full answer. See docs/SPEC.md, "Contrato con el modelo".
public struct Correction: Codable, Equatable, Sendable {
    public var edits: [Edit]
    public var corrected: String
    /// How the text sounds, e.g. "friendly · a bit informal", in the explanation language.
    public var tone: String?
}

public enum CorrectionParser {
    /// Parses the model output, tolerating surrounding prose or ```json fences.
    public static func parse(_ raw: String) throws -> Correction {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}") else {
            throw ParseError.noJSON
        }
        let data = Data(raw[start...end].utf8)
        return try JSONDecoder().decode(Correction.self, from: data)
    }

    public enum ParseError: Error { case noJSON }
}
