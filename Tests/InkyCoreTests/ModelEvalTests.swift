import Foundation
import Testing
@testable import InkyCore

/// Compares providers on the live-check prompt. Opt-in:
///   INKY_EVAL=1 INKY_EVAL_MODELS="claude:haiku,ollama:gemma3:4b" swift test --filter ModelEval
@Test(.enabled(if: ProcessInfo.processInfo.environment["INKY_EVAL"] == "1"))
func modelEval() async throws {
    struct Case: Decodable { var text: String; var expect: [String] }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/eval-sentences.json")
    let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    let specs = (ProcessInfo.processInfo.environment["INKY_EVAL_MODELS"] ?? "claude:haiku").split(separator: ",").map(String.init)
    let prompt = PromptBuilder(mode: .correct, tone: .casualProfessional, explanationLanguage: .spanish, live: true)

    for spec in specs {
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        let provider: Provider = parts[0] == "claude"
            ? ClaudeCodeProvider(model: parts[1], maxRequests: 4, purpose: "eval")
            : OpenAICompatibleProvider(baseURL: URL(string: "http://localhost:11434/v1")!, model: parts[1], apiKey: nil)
        var found = 0, expected = 0, falsePos = 0, badJSON = 0, total = 0.0
        var misses: [String] = []
        for c in cases {
            let start = Date()
            var edits: [Edit] = []
            do {
                edits = try CorrectionParser.parse(try await provider.complete(system: PromptBuilder.system, user: prompt.user(c.text))).edits
                    .filter { !$0.original.isEmpty && $0.original != $0.replacement }
            } catch { badJSON += 1 }
            total += Date().timeIntervalSince(start)
            // An expected error counts as found if some edit's original overlaps it.
            for exp in c.expect {
                expected += 1
                if edits.contains(where: { $0.original.localizedCaseInsensitiveContains(exp) || exp.localizedCaseInsensitiveContains($0.original) }) {
                    found += 1
                } else { misses.append("\(exp) ← \(c.text)") }
            }
            // Edits that don't touch any expected error, or in clean sentences.
            falsePos += edits.filter { e in
                !c.expect.contains { e.original.localizedCaseInsensitiveContains($0) || $0.localizedCaseInsensitiveContains(e.original) }
            }.count
            // Edits whose `original` isn't literally in the text can't be applied.
            badJSON += edits.contains { !c.text.contains($0.original) } ? 1 : 0
        }
        print("""
        [eval] \(spec): recall \(found)/\(expected) (\(Int(Double(found) / Double(expected) * 100))%) · \
        extra edits \(falsePos) · unusable answers \(badJSON)/\(cases.count) · avg \(String(format: "%.2f", total / Double(cases.count)))s
        """)
        for m in misses { print("   miss: \(m)") }
    }
}
