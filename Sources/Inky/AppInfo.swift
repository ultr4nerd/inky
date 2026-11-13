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

    struct Group { var key: String; var title: String; var note: String?; var ids: [String]; var defaultTone: String }

    /// The kinds of apps people write in. One list for everything: live-checking suggestions
    /// and the tone per kind of app (Settings → Tone), so adding an app to a kind does both.
    static func groups() -> [Group] {
        [Group(key: "work", title: L("Trabajo", "Work"), note: nil,
               ids: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.linear",
                     "com.atlassian.jira.mac", "notion.id", "us.zoom.xos"], defaultTone: "casual-professional"),
         Group(key: "mail", title: L("Correo", "Mail"), note: nil,
               ids: ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop"],
               defaultTone: "formal"),
         Group(key: "personal", title: L("Personal", "Personal"), note: nil,
               ids: ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "desktop.WhatsApp", "ru.keepcoder.Telegram",
                     "com.tdesktop.Telegram", "com.hnc.Discord"], defaultTone: "friendly"),
         Group(key: "notes", title: L("Notas", "Notes"), note: nil,
               ids: ["com.apple.Notes", "md.obsidian", "net.shinyfrog.bear", "com.lukilabs.lukiapp"], defaultTone: "neutral"),
         Group(key: "browsers", title: L("Navegadores", "Browsers"), note: L("Revisa todas las webs", "Checks every website"),
               ids: ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"], defaultTone: "neutral")]
    }

    /// The groups with only the installed apps (empty groups dropped).
    static func suggestedGroups() -> [Group] {
        groups().map { g in var g = g; g.ids = g.ids.filter { url($0) != nil }; return g }.filter { !$0.ids.isEmpty }
    }

    /// The kind of app a bundle id belongs to, if it's one Inky knows.
    static func group(of id: String?) -> Group? {
        guard let id else { return nil }
        return groups().first { $0.ids.contains(id) }
    }

    /// Work apps turned on by default for live checking (the installed ones).
    static func defaultLiveApps() -> [String] {
        ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.microsoft.teams", "com.apple.mail", "com.microsoft.Outlook", "com.linear"]
            .filter { url($0) != nil }
    }

    /// All suggested apps, flattened.
    static func writingApps() -> [String] { suggestedGroups().flatMap(\.ids) }

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
