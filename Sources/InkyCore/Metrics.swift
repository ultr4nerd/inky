import Foundation

/// Local usage metrics (never text): one JSON object per line in
/// ~/Library/Application Support/Inky/metrics.jsonl. Used to decide whether live checking
/// is worth it (accept rate, late underlines, quota use).
public enum Metrics {
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inky/metrics.jsonl")
    }

    private static let queue = DispatchQueue(label: "inky.metrics")

    public static func record(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = event
        obj["ts"] = ISO8601DateFormatter().string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = fileURL
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// Reads all events since `date`.
    public static func events(since date: Date) -> [[String: Any]] {
        guard let data = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let fmt = ISO8601DateFormatter()
        return data.split(separator: "\n").compactMap { line in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = obj["ts"] as? String, let d = fmt.date(from: ts), d >= date else { return nil }
            return obj
        }
    }
}
