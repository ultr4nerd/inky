import Foundation

/// Optional local history (off by default) so the user can review explanations later.
public struct HistoryEntry: Codable, Sendable {
    public var date: Date
    public var app: String?
    public var mode: Mode
    public var original: String
    public var corrected: String
    public var edits: [Edit]

    public init(date: Date, app: String?, mode: Mode, original: String, corrected: String, edits: [Edit]) {
        self.date = date; self.app = app; self.mode = mode
        self.original = original; self.corrected = corrected; self.edits = edits
    }
}

public enum HistoryStore {
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inky/history.jsonl")
    }

    public static func append(_ entry: HistoryEntry) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public static func clear() { try? FileManager.default.removeItem(at: fileURL) }
}
