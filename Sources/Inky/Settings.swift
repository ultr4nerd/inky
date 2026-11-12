import AppKit
import InkyCore
import Security
import SwiftUI

enum ProviderKind: String, CaseIterable, Identifiable {
    case claude, codex, openai
    var id: String { rawValue }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openai: "OpenAI-compatible (Ollama, LM Studio, API key)"
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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            provider: ProviderKind.claude.rawValue,
            claudeModel: "haiku",
            codexModel: "",
            openAIBaseURL: "http://localhost:11434/v1",
            openAIModel: "llama3.2",
            explanationLanguage: ExplanationLanguage.spanish.rawValue,
            historyEnabled: false,
            LiveController.enabledKey: false, // opt-in: it sends what you type to the provider
        ])
    }

    static var d: UserDefaults { .standard }
    static var explanationLang: ExplanationLanguage {
        ExplanationLanguage(rawValue: d.string(forKey: explanationLanguage) ?? "") ?? .spanish
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

struct SettingsView: View {
    @AppStorage(Prefs.provider) private var provider = ProviderKind.claude.rawValue
    @AppStorage(Prefs.claudeModel) private var claudeModel = "haiku"
    @AppStorage(Prefs.codexModel) private var codexModel = ""
    @AppStorage(Prefs.openAIBaseURL) private var baseURL = "http://localhost:11434/v1"
    @AppStorage(Prefs.openAIModel) private var openAIModel = "llama3.2"
    @AppStorage(Prefs.explanationLanguage) private var language = ExplanationLanguage.spanish.rawValue
    @AppStorage(Prefs.historyEnabled) private var history = false
    @State private var apiKey = Keychain.apiKey ?? ""
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Use", selection: $provider) {
                    ForEach(ProviderKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                switch ProviderKind(rawValue: provider) ?? .claude {
                case .claude:
                    TextField("Model", text: $claudeModel, prompt: Text("haiku"))
                    Text("Runs your installed `claude` CLI with your own login. Inky never touches your credentials.")
                        .font(.caption).foregroundStyle(.secondary)
                case .codex:
                    TextField("Model", text: $codexModel, prompt: Text("default"))
                    Text("Runs your installed `codex` CLI. Slower (~5 s per request).")
                        .font(.caption).foregroundStyle(.secondary)
                case .openai:
                    TextField("Base URL", text: $baseURL)
                    TextField("Model", text: $openAIModel)
                    SecureField("API key (optional)", text: $apiKey)
                        .onSubmit { Keychain.apiKey = apiKey }
                        .onDisappear { Keychain.apiKey = apiKey }
                }
            }
            Section("Explanations") {
                Picker("Language", selection: $language) {
                    ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
            }
            Section("History") {
                Toggle("Save corrections locally to review later", isOn: $history)
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.fileURL])
                    }
                    Button("Clear history", role: .destructive) { HistoryStore.clear() }
                }
            }
            Section("General") {
                Toggle("Open Inky at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
            }
            Section("Shortcut") {
                LabeledContent("Check text", value: "⌃⌥I")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
    }
}
