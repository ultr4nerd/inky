import AppKit

/// Names and icons for bundle identifiers (for the app lists in Settings).
@MainActor
enum AppInfo {
    static func url(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static func name(_ id: String) -> String? {
        guard let url = url(id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(_ id: String) -> NSImage {
        guard let url = url(id) else { return NSImage(systemSymbolName: "app", accessibilityDescription: nil)! }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Common apps people write in, if installed (suggestions for live checking).
    static func writingApps() -> [String] {
        ["com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.MobileSMS", "com.apple.Notes", "com.google.Chrome",
         "com.apple.Safari", "com.microsoft.teams2", "com.microsoft.Outlook", "net.whatsapp.WhatsApp", "com.hnc.Discord",
         "notion.id", "com.linear"].filter { url($0) != nil }
    }

    /// Apps running right now with a window (candidates to add).
    static func running() -> [(id: String, name: String)] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, seen.insert(id).inserted else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    /// Lets the user pick an app from /Applications.
    static func choose() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}
