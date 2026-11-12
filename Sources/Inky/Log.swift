import Foundation

/// Appends to ~/Library/Logs/Inky.log (never logs the user's text, only events and errors).
enum Log {
    static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Inky.log")

    static func info(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: .now)) \(message)\n"
        NSLog("Inky: %@", message)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
