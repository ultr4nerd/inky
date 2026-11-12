import Foundation
import Testing
@testable import InkyCore

/// Calls the real `claude` CLI. Opt-in: INKY_LIVE=1 swift test --filter Live
@Test(.enabled(if: ProcessInfo.processInfo.environment["INKY_LIVE"] == "1"))
func liveClaudeCorrectsAndKeepsMentions() async throws {
    let text = "hey @Ana this are a test, can you sent me the file when you will have time?"
    let protected = [NSRange(location: 4, length: 4)]
    let masked = MentionMasker.mask(text, protected: protected)
    let provider = ClaudeCodeProvider(model: "haiku")
    for mode in [Mode.correct, .shorter] {
        let prompt = PromptBuilder(mode: mode, tone: .casualProfessional, explanationLanguage: .spanish)
        let start = Date()
        let raw = try await provider.complete(system: PromptBuilder.system, user: prompt.user(masked.text))
        let c = try CorrectionParser.parse(raw)
        let planned = EditPlanner.plan(text: text, edits: EditPlanner.prepare(c.edits, placeholders: masked.placeholders), protected: protected)
        let result = EditPlanner.apply(planned, to: text)
        print("[\(mode)] \(String(format: "%.2f", Date().timeIntervalSince(start)))s tone=\(c.tone ?? "-") → \(result)")
        for p in planned { print("   - [\(p.category)] \((text as NSString).substring(with: p.range)) → \(p.replacement): \(p.explanation)") }
        #expect(result.contains("@Ana"))
        #expect(!planned.isEmpty)
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["INKY_LIVE"] == "1"))
func liveModeSentenceLatency() async throws {
    let provider = ClaudeCodeProvider(model: "haiku")
    await provider.warmUp(system: PromptBuilder.system)
    let prompt = PromptBuilder(mode: .correct, tone: .casualProfessional, explanationLanguage: .spanish, live: true)
    for s in ["hey this are a test, can you sent me the file when you will have time?",
              "I am agree with you, lets do it on monday.\nHe don't know nothing about the deploy.\nThanks, that works for me.",
              "Thanks, that works for me.",
              "Sounds good, I'll take a look tomorrow."] {
        let start = Date()
        let c = try CorrectionParser.parse(try await provider.complete(system: PromptBuilder.system, user: prompt.user(s)))
        print("[live] \(String(format: "%.2f", Date().timeIntervalSince(start)))s \(s)")
        for e in c.edits { print("   - [\(e.kind)] \(e.original) → \(e.replacement): \(e.explanation)") }
    }
}
