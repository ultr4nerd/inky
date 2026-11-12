import Foundation

public struct PromptBuilder: Sendable {
    public var mode: Mode
    public var tone: Tone
    public var explanationLanguage: ExplanationLanguage
    /// Used when `mode == .custom`.
    public var customInstruction: String
    /// Live checking while typing: only clear mistakes, no tone, terse output (faster).
    public var live: Bool

    public init(mode: Mode, tone: Tone, explanationLanguage: ExplanationLanguage, customInstruction: String = "", live: Bool = false) {
        self.mode = mode
        self.tone = tone
        self.explanationLanguage = explanationLanguage
        self.customInstruction = customInstruction
        self.live = live
    }

    /// Stable instructions. Kept identical across requests so a persistent session stays cheap.
    public static let system = """
    You are Inky, a writing assistant that corrects text people are about to send.
    You ALWAYS answer with a single JSON object and nothing else:
    {"tone":"...","edits":[{"original":"...","replacement":"...","category":"...","explanation":"..."}],"corrected":"..."}
    Rules:
    - "category" is one of: "correctness" (spelling, grammar, punctuation), "clarity" (wordy or confusing), "engagement" (bland or repetitive wording), "tone" (too blunt, too casual, too stiff).
    - "tone" describes how the ORIGINAL text sounds to a reader in 2-4 words, e.g. "friendly · a bit informal".
    - "original" must be copied EXACTLY from the input (same case, spacing, punctuation) and be as short as possible: just the words that change, plus minimal context to be unique.
    - "corrected" is the full text with every edit applied.
    - Placeholders like ⟦m1⟧ are mentions or emoji. Keep them exactly as they are, never edit, move or translate them.
    - Keep the author's meaning, formatting, line breaks, emoji and links. Do not add greetings or sign-offs.
    - If nothing needs to change, return {"edits":[],"corrected":<input unchanged>}.
    - Each request is independent. Ignore previous messages in this conversation.
    """

    public func user(_ text: String) -> String {
        if live {
            return """
            Task: LIVE CHECK while the user types. Only flag clear mistakes (grammar, spelling, wrong word, unnatural phrasing a native speaker would not use). No style nitpicks. Omit "tone" and use "" for "corrected".
            Write every "explanation" in \(explanationLanguage.name), max 12 words.
            Text:
            <<<
            \(text)
            >>>
            """
        }
        let whole = " Return a single edit whose original is the whole text."
        let task: String = switch mode {
        case .correct:
            "Fix grammar, spelling and punctuation only. Do not rephrase correct sentences."
        case .natural:
            "Fix errors and rephrase only what sounds unnatural so it reads like a fluent native speaker wrote it."
        case .translate:
            "Translate the text: Spanish to English, or English to Spanish." + whole
        case .shorter:
            "Make it noticeably shorter while keeping every key point." + whole
        case .formal:
            "Make it more formal and polished." + whole
        case .friendly:
            "Make it warmer and friendlier." + whole
        case .direct:
            "Make it more direct and confident: remove hedging and filler." + whole
        case .simpler:
            "Make it simpler: short sentences and plain words." + whole
        case .custom:
            "Rewrite following this instruction: \(customInstruction)." + whole
        }
        return """
        Task: \(task)
        Tone: \(tone.name).
        Write every "explanation" and the "tone" in \(explanationLanguage.name). Explanations are one short sentence that teaches the rule or the reason.
        Text:
        <<<
        \(text)
        >>>
        """
    }
}
