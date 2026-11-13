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
    static let toneSlack = "toneSlack"
    static let toneMail = "toneMail"
    static let toneOther = "toneOther"

    static let toneChoices = ["casual-professional", "friendly", "neutral", "formal"]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: ProviderKind.claude.rawValue,
            claudeModel: "haiku",
            codexModel: "",
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
            toneSlack: "casual-professional",
            toneMail: "formal",
            toneOther: "neutral",
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

    /// Tone for the app the text comes from (Settings → Tone).
    static func tone(forBundleID id: String?) -> Tone {
        switch id {
        case "com.tinyspeck.slackmacgap": Tone(d.string(forKey: toneSlack) ?? "casual-professional")
        case "com.apple.mail", "com.microsoft.Outlook": Tone(d.string(forKey: toneMail) ?? "formal")
        default: Tone(d.string(forKey: toneOther) ?? "neutral")
        }
    }

    /// Builds the provider for the current settings.
    static func makeProvider(purpose: String = "panel") -> Provider {
        switch ProviderKind(rawValue: d.string(forKey: provider) ?? "") ?? .claude {
        case .claude: ClaudeCodeProvider(model: d.string(forKey: claudeModel) ?? "haiku",
                                         maxRequests: purpose == "live" ? 4 : 6, purpose: purpose)
        case .codex: CodexProvider(model: d.string(forKey: codexModel))
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

