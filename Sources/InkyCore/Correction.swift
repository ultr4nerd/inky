import Foundation

/// A single change proposed by the model.
public struct Edit: Codable, Equatable, Sendable {
    public var original: String
    public var replacement: String
    public var explanation: String

    public init(original: String, replacement: String, explanation: String) {
        self.original = original
        self.replacement = replacement
        self.explanation = explanation
    }
}

/// The model's full answer. See docs/SPEC.md, "Contrato con el modelo".
public struct Correction: Codable, Equatable, Sendable {
    public var edits: [Edit]
    public var corrected: String
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
