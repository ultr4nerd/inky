import Foundation

/// Replaces protected ranges (mentions, channels, emoji) with placeholders like ⟦m1⟧
/// so the model can't alter them, and maps them back afterwards.
public struct MaskedText: Equatable, Sendable {
    public var text: String
    public var placeholders: [String: String]   // "⟦m1⟧" -> "@Ana"
}

public enum MentionMasker {
    public static func mask(_ text: String, protected ranges: [NSRange]) -> MaskedText {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var map: [String: String] = [:]
        for (i, r) in ranges.sorted(by: { $0.location < $1.location }).enumerated()
        where r.location >= cursor && NSMaxRange(r) <= ns.length {
            out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let key = "⟦m\(i + 1)⟧"
            map[key] = ns.substring(with: r)
            out += key
            cursor = NSMaxRange(r)
        }
        out += ns.substring(from: cursor)
        return MaskedText(text: out, placeholders: map)
    }

    public static func unmask(_ text: String, _ placeholders: [String: String]) -> String {
        placeholders.reduce(text) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
    }
}
