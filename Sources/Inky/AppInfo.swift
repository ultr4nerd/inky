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

    struct Group { var title: String; var note: String?; var ids: [String] }

    /// Apps people write in, by kind (only the installed ones are shown).
    static func suggestedGroups() -> [Group] {
        [Group(title: L("Trabajo", "Work"), note: nil,
               ids: ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.linear", "com.atlassian.jira.mac",
                     "notion.id", "us.zoom.xos"]),
         Group(title: L("Correo", "Mail"), note: nil,
               ids: ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron", "com.readdle.SparkDesktop"]),
         Group(title: L("Personal", "Personal"), note: nil,
               ids: ["com.apple.MobileSMS", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "com.hnc.Discord", "com.apple.Notes"]),
         Group(title: L("Navegadores", "Browsers"), note: L("Revisa todas las webs", "Checks every website"),
               ids: ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser"])]
            .map { Group(title: $0.title, note: $0.note, ids: $0.ids.filter { url($0) != nil }) }
            .filter { !$0.ids.isEmpty }
    }

    /// Work apps turned on by default for live checking (the installed ones).
    static func defaultLiveApps() -> [String] {
        ["com.tinyspeck.slackmacgap", "com.microsoft.teams2", "com.apple.mail", "com.microsoft.Outlook", "com.linear"]
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
