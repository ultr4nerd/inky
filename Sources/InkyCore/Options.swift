import Foundation

public enum Mode: String, CaseIterable, Codable, Sendable {
    // Primary modes (cycled with Tab)
    case correct, natural, translate
    // Rewrites (menu)
    case shorter, formal, friendly, direct, simpler
    /// Free-form instruction typed by the user.
    case custom

    public static let primary: [Mode] = [.correct, .natural, .translate]
    public static let rewrites: [Mode] = [.shorter, .formal, .friendly, .direct, .simpler]

    public var isPrimary: Bool { Mode.primary.contains(self) }

    public func next() -> Mode {
        let p = Mode.primary
        guard let i = p.firstIndex(of: self) else { return .correct }
        return p[(i + 1) % p.count]
    }

    public func previous() -> Mode {
        let p = Mode.primary
        guard let i = p.firstIndex(of: self) else { return .correct }
        return p[(i + p.count - 1) % p.count]
    }
}

public enum ExplanationLanguage: String, CaseIterable, Codable, Sendable {
    case english = "en", spanish = "es"
    public var name: String { self == .english ? "English" : "Spanish" }
}

public struct Tone: Codable, Equatable, Sendable {
    public var name: String
    public init(_ name: String) { self.name = name }

    public static let casualProfessional = Tone("casual-professional")
    public static let formal = Tone("formal")
    public static let neutral = Tone("neutral")

    /// Default tone per app bundle identifier (docs/SPEC.md, "Tonos por app").
    public static func `default`(forBundleID id: String?) -> Tone {
        switch id {
        case "com.tinyspeck.slackmacgap": .casualProfessional
        case "com.apple.mail", "com.microsoft.Outlook": .formal
        default: .neutral
        }
    }
}
