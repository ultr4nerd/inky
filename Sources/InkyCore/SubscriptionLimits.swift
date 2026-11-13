import Foundation

/// The subscription limit windows Claude Code reports with every response
/// (`rate_limit_event`): how much of the 5-hour / weekly limit the whole account has used.
public struct LimitWindow: Codable, Sendable, Equatable {
    public var kind: String          // "five_hour", "seven_day", …
    public var utilization: Double   // 0…1, account-wide
    public var resetsAt: Date
}

public enum SubscriptionLimits {
    public struct Snapshot: Codable, Sendable {
        public var windows: [LimitWindow]
        public var updated: Date
    }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inky/limits.json")
    }

    static func save(_ info: [String: Any]) {
        var windows: [LimitWindow] = []
        if let unified = info["unifiedWindows"] as? [String: Any] {
            for (kind, value) in unified {
                guard let w = value as? [String: Any], let u = w["utilization"] as? Double,
                      let r = w["resetsAt"] as? Double else { continue }
                windows.append(LimitWindow(kind: kind, utilization: u, resetsAt: Date(timeIntervalSince1970: r)))
            }
        }
        guard !windows.isEmpty else { return }
        let snap = Snapshot(windows: windows.sorted { $0.kind < $1.kind }, updated: Date())
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// The last reported limits, if any.
    public static func latest() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}
