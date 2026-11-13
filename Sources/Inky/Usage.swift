import Foundation
import InkyCore

/// How much of the user's Claude subscription Inky uses.
///
/// Claude Code reports the account-wide limit usage (e.g. weekly: 31%). It doesn't split it
/// by app, so Inky estimates its share: it prices every Claude Code request made on this Mac
/// during the limit window (from the token counts in `~/.claude/projects`, never the text),
/// and takes Inky's fraction of that. Usage elsewhere (claude.ai, other machines) isn't in
/// those files, so the estimate can only overstate Inky's share, never understate it.
struct UsageReport: Sendable {
    var window: LimitWindow
    var otherWindows: [LimitWindow]
    var totalCost: Double         // API-equivalent $, all Claude Code on this Mac in the window
    var inkyCost: Double
    var inkyRequests: Int
    var inkyTokens: Int

    /// Inky's estimated share of the limit (0…1), e.g. 0.015 = 1.5% of the weekly limit.
    var inkyShare: Double { totalCost > 0 ? window.utilization * min(1, inkyCost / totalCost) : 0 }
    /// Share of the limit one Inky request uses, on average.
    var perRequest: Double { inkyRequests > 0 ? inkyShare / Double(inkyRequests) : 0 }
}

@MainActor
enum Usage {
    private static var cached: (date: Date, report: UsageReport?)?

    /// Cached for 5 minutes; the scan (off the main thread) reads only files touched during the window.
    static func report() async -> UsageReport? {
        if let c = cached, Date().timeIntervalSince(c.date) < 300 { return c.report }
        let r = await Task.detached(priority: .utility) { compute() }.value
        cached = (Date(), r)
        return r
    }

    /// The last computed report, without scanning (for synchronous UI like alerts).
    static var last: UsageReport? { cached?.report }

    nonisolated private static func compute() -> UsageReport? {
        guard let snap = SubscriptionLimits.latest(),
              let window = snap.windows.first(where: { $0.kind == "seven_day" }) ?? snap.windows.first else { return nil }
        let length: TimeInterval = window.kind == "five_hour" ? 5 * 3600 : 7 * 86400
        let start = window.resetsAt.addingTimeInterval(-length)
        let startISO = ISO8601DateFormatter().string(from: start)

        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var total = 0.0, inky = 0.0, inkyRequests = 0, inkyTokens = 0
        var seen = Set<String>()
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                   options: [.skipsHiddenFiles])
        let needle = Data("\"usage\"".utf8)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mod >= start, let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            let isInky = url.path.contains("Application-Support-Inky-work")
            for line in data.split(separator: 0x0A) where line.range(of: needle) != nil {
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let ts = obj["timestamp"] as? String, ts >= startISO,
                      let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                let id = (msg["id"] as? String) ?? (obj["requestId"] as? String) ?? UUID().uuidString
                guard seen.insert(id).inserted else { continue }   // streamed messages repeat
                let cost = price(model: msg["model"] as? String ?? "", usage: usage)
                total += cost
                if isInky {
                    inky += cost
                    inkyRequests += 1
                    inkyTokens += ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                        .reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
                }
            }
        }
        return UsageReport(window: window, otherWindows: snap.windows.filter { $0 != window },
                           totalCost: total, inkyCost: inky, inkyRequests: inkyRequests, inkyTokens: inkyTokens)
    }

    /// API prices per million tokens: (input, output, cache read). Cache writes: 1.25× input
    /// (5 min) or 2× input (1 h). Only the ratio between apps matters here.
    nonisolated private static func rates(_ model: String) -> (Double, Double, Double) {
        let table: [(String, (Double, Double, Double))] = [
            ("fable-5-2", (8, 40, 0.2)), ("mythos-5-2", (8, 40, 0.2)),
            ("fable-5", (10, 50, 1)), ("mythos-5", (10, 50, 1)),
            ("opus-5-5", (4, 20, 0.2)), ("opus-5", (5, 25, 0.5)), ("opus-4", (5, 25, 0.5)),
            ("sonnet-5-5", (2, 10, 0.1)), ("sonnet-5", (2, 10, 0.2)), ("sonnet-4", (3, 15, 0.3)),
            ("haiku-5-5", (0.1, 0.5, 0.01)), ("haiku-4", (1, 5, 0.1)),
        ]
        return table.first { model.contains($0.0) }?.1 ?? (4, 20, 0.2)
    }

    nonisolated private static func price(model: String, usage: [String: Any]) -> Double {
        let (i, o, r) = rates(model)
        func n(_ k: String) -> Double { Double(usage[k] as? Int ?? 0) }
        var write5 = n("cache_creation_input_tokens"), write1h = 0.0
        if let c = usage["cache_creation"] as? [String: Any] {
            write5 = Double(c["ephemeral_5m_input_tokens"] as? Int ?? 0)
            write1h = Double(c["ephemeral_1h_input_tokens"] as? Int ?? 0)
        }
        return (n("input_tokens") * i + n("output_tokens") * o + n("cache_read_input_tokens") * r
                + write5 * i * 1.25 + write1h * i * 2) / 1_000_000
    }
}

extension UsageReport {
    /// "31%", "1.5%", "0.02%".
    static func pct(_ x: Double) -> String {
        let p = x * 100
        if p >= 10 { return "\(Int(p.rounded()))%" }
        if p >= 1 { return String(format: "%.1f%%", p) }
        if p >= 0.01 { return String(format: "%.2f%%", p) }
        if p > 0 { return "<0.01%" }
        return "0%"
    }

    /// "≈ 1.5%" or "menos del 0.01%" for tiny amounts.
    static func approx(_ x: Double) -> String {
        let p = pct(x)
        return p.hasPrefix("<") ? L("menos del 0.01%", "under 0.01%") : "≈ " + p
    }

    var windowName: String {
        window.kind == "five_hour" ? L("límite de 5 horas", "5-hour limit") : L("límite semanal", "weekly limit")
    }

    var resetText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: Prefs.uiLang == .spanish ? "es" : "en")
        f.setLocalizedDateFormatFromTemplate(window.kind == "five_hour" ? "jmm" : "EEEd")
        return f.string(from: window.resetsAt)
    }
}
