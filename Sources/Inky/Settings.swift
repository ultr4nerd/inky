import AppKit
import InkyCore
import Security
import SwiftUI

/// UI string in the interface language (Settings → General).
func L(_ es: String, _ en: String) -> String { Prefs.uiLang == .spanish ? es : en }

/// Tone names for pickers.
func toneTitle(_ t: String) -> String {
    switch t {
    case "casual-professional": L("Casual profesional", "Casual professional")
    case "friendly": L("Amigable", "Friendly")
    case "formal": L("Formal", "Formal")
    default: L("Neutro", "Neutral")
    }
}

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude, codex, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openai: L("Compatible con OpenAI (Ollama, LM Studio, API key)", "OpenAI-compatible (Ollama, LM Studio, API key)")
        }
    }
}

/// UserDefaults keys. The API key lives in the Keychain.
enum Prefs {
    static let provider = "provider"
    static let claudeModel = "claudeModel"
    static let codexModel = "codexModel"
    static let openAIBaseURL = "openAIBaseURL"
    static let openAIModel = "openAIModel"
    static let explanationLanguage = "explanationLanguage"
    static let historyEnabled = "historyEnabled"
    static let uiLanguage = "uiLanguage"
    static let hotkeyCode = "hotkeyCode"
    static let hotkeyMods = "hotkeyMods"
    static let hotkeyLabel = "hotkeyLabel"
    static let livePause = "livePause"
    static let liveCategories = "liveCategories"
    static let toneOther = "toneOther"

    static let liveScope = "liveScope"          // "list": only liveApps; "all": every app except liveBlocked
    static let liveApps = "liveApps"
    static let liveBlocked = "liveBlocked"

    /// Never checked live, whatever the settings: terminals and password managers.
    static let neverLive: Set<String> = [
        "dev.ultr4nerd.inky", "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.1password.1password",
        "com.agilebits.onepassword7", "com.bitwarden.desktop", "com.apple.keychainaccess", "com.apple.Passwords",
    ]
    /// Blocked by default when live checking is on in every app (code, where corrections don't apply).
    static let defaultBlocked = ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.apple.dt.Xcode"]

    static let toneChoices = ["casual-professional", "friendly", "neutral", "formal"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: ProviderKind.claude.rawValue,
            claudeModel: "haiku",
            codexModel: "luna",   // a family; resolved to its newest version (fast and affordable)
            openAIBaseURL: "http://localhost:11434/v1",
            openAIModel: "llama3.2",
            explanationLanguage: systemLanguage.rawValue,
            historyEnabled: false,
            LiveController.enabledKey: false, // opt-in: it sends what you type to the provider
            uiLanguage: systemLanguage.rawValue,
            hotkeyCode: 34,                                    // kVK_ANSI_I
            hotkeyMods: Int(CGEventFlags([.maskControl, .maskAlternate]).rawValue),
            hotkeyLabel: "⌃⌥I",
            livePause: 1.2,
            liveCategories: ["correctness", "clarity"],
            toneOther: "neutral",
            liveScope: "list",
            liveApps: MainActor.assumeIsolated { AppInfo.defaultLiveApps() },
            liveBlocked: defaultBlocked,
        ])
    }

    static var d: UserDefaults { .standard }

    /// Spanish if it's the Mac's first language, English otherwise (until chosen in Settings).
    static var systemLanguage: ExplanationLanguage {
        (Locale.preferredLanguages.first ?? "en").hasPrefix("es") ? .spanish : .english
    }
    static var explanationLang: ExplanationLanguage {
        ExplanationLanguage(rawValue: d.string(forKey: explanationLanguage) ?? "") ?? .spanish
    }

    static var uiLang: ExplanationLanguage {
        ExplanationLanguage(rawValue: d.string(forKey: uiLanguage) ?? "") ?? .spanish
    }
    static var shortcut: String { d.string(forKey: hotkeyLabel) ?? "⌃⌥I" }
    static var pause: TimeInterval { max(0.5, d.double(forKey: livePause)) }
    static var categories: [EditCategory] {
        (d.stringArray(forKey: liveCategories) ?? []).compactMap(EditCategory.init(rawValue:))
    }

    static var liveEverywhere: Bool { d.string(forKey: liveScope) == "all" }

    /// Whether live checking runs in this app (Settings → Live → Where).
    static func liveAllowed(_ id: String?) -> Bool {
        guard let id, !neverLive.contains(id) else { return false }
        return liveEverywhere ? !(d.stringArray(forKey: liveBlocked) ?? []).contains(id)
                              : (d.stringArray(forKey: liveApps) ?? []).contains(id)
    }

    /// "Slack", "3 apps", "todas las apps" — for labels.
    @MainActor static var liveWhere: String {
        if liveEverywhere { return L("todas las apps", "every app") }
        let apps = d.stringArray(forKey: liveApps) ?? []
        if apps.count == 1, let name = AppInfo.name(apps[0]) { return name }
        return L("\(apps.count) apps", "\(apps.count) apps")
    }

    static func toneKey(_ group: String) -> String { "tone." + group }

    /// Tone for the app the text comes from: its kind of app (Settings → Tone), else "other apps".
    @MainActor static func tone(forBundleID id: String?) -> Tone {
        if let g = AppInfo.group(of: id) { return Tone(d.string(forKey: toneKey(g.key)) ?? g.defaultTone) }
        return Tone(d.string(forKey: toneOther) ?? "neutral")
    }

    /// Builds the provider for the current settings.
    static func makeProvider(purpose: String = "panel") -> Provider {
        switch ProviderKind(rawValue: d.string(forKey: provider) ?? "") ?? .claude {
        case .claude: ClaudeCodeProvider(model: d.string(forKey: claudeModel) ?? "haiku",
                                         maxRequests: purpose == "live" ? 4 : 6, purpose: purpose)
        case .codex: CodexProvider(model: CodexModels.resolve(d.string(forKey: codexModel) ?? "luna"))
        case .openai:
            OpenAICompatibleProvider(baseURL: URL(string: d.string(forKey: openAIBaseURL) ?? "") ?? URL(string: "http://localhost:11434/v1")!,
                                     model: d.string(forKey: openAIModel) ?? "", apiKey: Keychain.apiKey)
        }
    }

    /// Changes to these keys require a new provider instance.
    static var providerSignature: String {
        [provider, claudeModel, codexModel, openAIBaseURL, openAIModel].map { d.string(forKey: $0) ?? "" }.joined(separator: "|")
            + "|\(Keychain.apiKey?.count ?? 0)"
    }
}

/// Claude models are CLI aliases ("haiku" → the newest Haiku), so they update by themselves.
enum ClaudeModels {
    static let choices: [(alias: String, es: String, en: String)] = [
        ("haiku", "Haiku · el más rápido y barato", "Haiku · fastest and cheapest"),
        ("sonnet", "Sonnet · más cuidadoso, más lento", "Sonnet · more careful, slower"),
        ("opus", "Opus · el más capaz, gasta mucho más", "Opus · most capable, uses much more"),
    ]
}

/// Codex has no aliases, so Inky stores a family ("luna") and picks the newest model of that
/// family from Codex's own model list (~/.codex/models_cache.json) on every check.
enum CodexModels {
    static let choices: [(family: String, es: String, en: String)] = [
        ("luna", "Luna · rápido y económico", "Luna · fast and affordable"),
        ("terra", "Terra · equilibrado", "Terra · balanced"),
        ("sol", "Sol · más capaz, más lento", "Sol · more capable, slower"),
    ]

    /// "luna" → "gpt-6-luna" (the highest version available). A full model id passes through.
    static func resolve(_ family: String) -> String {
        let fam = family.split(separator: "-").last.map(String.init) ?? family   // "gpt-6-luna" → "luna"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/models_cache.json")
        guard choices.contains(where: { $0.family == fam }),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return family }
        let slugs = models.compactMap { $0["slug"] as? String ?? $0["id"] as? String }.filter { $0.hasSuffix("-" + fam) }
        return slugs.max { version($0).lexicographicallyPrecedes(version($1)) } ?? family
    }

    /// "gpt-6.1-sol" → [6, 1]
    private static func version(_ slug: String) -> [Int] {
        let parts = slug.split(separator: "-")
        guard parts.count >= 3 else { return [] }
        return parts[1].split(separator: ".").compactMap { Int($0) }
    }
}

enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "dev.ultr4nerd.inky",
                                               kSecAttrAccount as String: "openai-api-key"]
    static var apiKey: String? {
        get {
            var q = query
            q[kSecReturnData as String] = true
            var out: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        set {
            SecItemDelete(query as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var q = query
            q[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

