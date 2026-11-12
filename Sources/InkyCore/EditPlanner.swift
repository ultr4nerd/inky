import Foundation

/// A concrete replacement in the field, in UTF-16 offsets (what Accessibility uses).
public struct PlannedEdit: Equatable, Sendable {
    public var range: NSRange
    public var replacement: String
    public var explanation: String
    public var category: EditCategory

    public init(range: NSRange, replacement: String, explanation: String, category: EditCategory = .correctness) {
        self.range = range; self.replacement = replacement; self.explanation = explanation; self.category = category
    }
}

public enum EditPlanner {
    /// Locates each edit's `original` in `text`, in order, skipping edits that are not
    /// found or that overlap a protected range. Returned last-to-first so they can be
    /// applied without shifting earlier offsets.
    public static func plan(text: String, edits: [Edit], protected: [NSRange] = []) -> [PlannedEdit] {
        let ns = text as NSString
        var cursor = 0
        var planned: [PlannedEdit] = []
        for edit in edits where !edit.original.isEmpty && edit.original != edit.replacement {
            var r = ns.range(of: edit.original, range: NSRange(location: cursor, length: ns.length - cursor))
            if r.location == NSNotFound { r = ns.range(of: edit.original) } // model returned out of order
            guard r.location != NSNotFound,
                  !protected.contains(where: { NSIntersectionRange($0, r).length > 0 }),
                  !planned.contains(where: { NSIntersectionRange($0.range, r).length > 0 })
            else { continue }
            planned.append(PlannedEdit(range: r, replacement: edit.replacement, explanation: edit.explanation, category: edit.kind))
            cursor = NSMaxRange(r)
        }
        return planned.sorted { $0.range.location > $1.range.location }
    }

    public static func apply(_ planned: [PlannedEdit], to text: String) -> String {
        let s = NSMutableString(string: text)
        for p in planned.sorted(by: { $0.range.location > $1.range.location }) {
            s.replaceCharacters(in: p.range, with: p.replacement)
        }
        return s as String
    }
}

extension EditPlanner {
    /// The model sees mentions as ⟦m1⟧. If an edit spans a placeholder (e.g. a whole-text
    /// translation), split it into the pieces between placeholders so mentions are never
    /// retyped. Then restore any remaining placeholders to their real text.
    public static func prepare(_ edits: [Edit], placeholders: [String: String]) -> [Edit] {
        guard !placeholders.isEmpty else { return edits }
        let token = try! Regex("⟦m[0-9]+⟧")
        var result: [Edit] = []
        for edit in edits {
            let origTokens = edit.original.matches(of: token).map { String(edit.original[$0.range]) }
            guard !origTokens.isEmpty else { result.append(edit); continue }
            let replTokens = edit.replacement.matches(of: token).map { String(edit.replacement[$0.range]) }
            guard origTokens == replTokens else { continue } // model moved/dropped a mention: unsafe
            let o = edit.original.split(separator: token, omittingEmptySubsequences: false).map(String.init)
            let r = edit.replacement.split(separator: token, omittingEmptySubsequences: false).map(String.init)
            for (a, b) in zip(o, r) where a != b && !a.isEmpty {
                result.append(Edit(original: a, replacement: b, explanation: edit.explanation, category: edit.category))
            }
        }
        return result.map {
            Edit(original: MentionMasker.unmask($0.original, placeholders),
                 replacement: MentionMasker.unmask($0.replacement, placeholders),
                 explanation: $0.explanation, category: $0.category)
        }
    }
}
