import AppKit
import Carbon.HIToolbox
import InkyCore
import SwiftUI

extension Notification.Name {
    /// Posted when the user records a new global shortcut.
    static let inkyShortcutChanged = Notification.Name("inkyShortcutChanged")
}

/// Settings, in tabs. Strings follow the interface language and refresh when it changes.
struct SettingsView: View {
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = ExplanationLanguage.spanish.rawValue

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label(L("General", "General"), systemImage: "gearshape") }
            LiveTab().tabItem { Label(L("En vivo", "Live"), systemImage: "waveform") }
            ToneTab().tabItem { Label(L("Tono", "Tone"), systemImage: "text.bubble") }
            ProviderTab().tabItem { Label(L("Proveedor", "Provider"), systemImage: "cpu") }
            HistoryTab().tabItem { Label(L("Historial", "History"), systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 500)
        .id(uiLanguage)   // rebuild every string when the language changes
    }
}

private struct GeneralTab: View {
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = ExplanationLanguage.spanish.rawValue
    @AppStorage(Prefs.explanationLanguage) private var language = ExplanationLanguage.spanish.rawValue
    @State private var openAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Picker(L("Idioma de Inky", "Inky's language"), selection: $uiLanguage) {
                    ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.nativeName).tag($0.rawValue) }
                }
                Picker(L("Explicar las correcciones en", "Explain corrections in"), selection: $language) {
                    ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.nativeName).tag($0.rawValue) }
                }
            }
            Section {
                LabeledContent(L("Revisar texto", "Check text")) { ShortcutRecorder() }
                Toggle(L("Abrir Inky al iniciar sesión", "Open Inky at login"), isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in LoginItem.set(on) }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LiveTab: View {
    @AppStorage(LiveController.enabledKey) private var enabled = false
    @AppStorage(Prefs.livePause) private var pause = 1.2
    @State private var categories: Set<String> = Set(Prefs.categories.map(\.rawValue))

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { on in
                    if !on || LivePrivacy.confirm() { LivePrivacy.set(on) }
                })) {
                    Text(L("Revisión en vivo en Slack", "Live checking in Slack"))
                    Text(L("Mientras está encendida, cada oración que escribes se envía a tu proveedor al hacer una pausa. La gota junto al campo lleva un anillo.",
                           "While it's on, every sentence you type is sent to your provider when you pause. The drop next to the field shows a ring."))
                }
            }
            Section(L("Cuándo revisar", "When to check")) {
                LabeledContent(L("Pausa antes de revisar", "Pause before checking")) {
                    HStack {
                        Slider(value: $pause, in: 0.6...3, step: 0.2).frame(width: 160)
                        Text(String(format: "%.1f s", pause)).monospacedDigit().foregroundStyle(.secondary).frame(width: 40)
                    }
                }
            }
            Section(L("Qué subrayar", "What to underline")) {
                ForEach(EditCategory.allCases, id: \.rawValue) { c in
                    Toggle(isOn: Binding(get: { categories.contains(c.rawValue) }, set: { on in
                        if on { categories.insert(c.rawValue) } else if categories.count > 1 { categories.remove(c.rawValue) }
                        UserDefaults.standard.set(EditCategory.allCases.map(\.rawValue).filter(categories.contains), forKey: Prefs.liveCategories)
                    })) {
                        HStack(spacing: 8) {
                            Circle().fill(Ink.color(c)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(categoryTitle(c))
                                Text(categoryHint(c)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func categoryTitle(_ c: EditCategory) -> String {
        switch c {
        case .correctness: L("Corrección", "Correctness")
        case .clarity: L("Claridad", "Clarity")
        case .engagement: L("Interés", "Engagement")
        case .tone: L("Tono", "Tone")
        }
    }

    private func categoryHint(_ c: EditCategory) -> String {
        switch c {
        case .correctness: L("Gramática, ortografía, palabra equivocada", "Grammar, spelling, wrong word")
        case .clarity: L("Frases confusas o poco naturales", "Confusing or unnatural phrasing")
        case .engagement: L("Palabras sosas o repetidas", "Bland or repeated wording")
        case .tone: L("Demasiado brusco, informal o rígido", "Too blunt, casual or stiff")
        }
    }
}

private struct ToneTab: View {
    @AppStorage(Prefs.toneSlack) private var slack = "casual-professional"
    @AppStorage(Prefs.toneMail) private var mail = "formal"
    @AppStorage(Prefs.toneOther) private var other = "neutral"

    var body: some View {
        Form {
            Section {
                picker("Slack", $slack)
                picker(L("Mail y Outlook", "Mail and Outlook"), $mail)
                picker(L("Otras apps", "Other apps"), $other)
            } footer: {
                Text(L("El tono que Inky busca al corregir y reescribir en cada app.", "The tone Inky aims for when correcting and rewriting in each app."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func picker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(Prefs.toneChoices, id: \.self) { Text(toneTitle($0)).tag($0) }
        }
    }
}

private struct ProviderTab: View {
    @AppStorage(Prefs.provider) private var provider = ProviderKind.claude.rawValue
    @AppStorage(Prefs.claudeModel) private var claudeModel = "haiku"
    @AppStorage(Prefs.codexModel) private var codexModel = ""
    @AppStorage(Prefs.openAIBaseURL) private var baseURL = "http://localhost:11434/v1"
    @AppStorage(Prefs.openAIModel) private var openAIModel = "llama3.2"
    @State private var apiKey = Keychain.apiKey ?? ""

    var body: some View {
        Form {
            Section {
                Picker(L("Usar", "Use"), selection: $provider) {
                    ForEach(ProviderKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                switch ProviderKind(rawValue: provider) ?? .claude {
                case .claude:
                    TextField(L("Modelo", "Model"), text: $claudeModel, prompt: Text("haiku"))
                case .codex:
                    TextField(L("Modelo", "Model"), text: $codexModel, prompt: Text(L("predeterminado", "default")))
                case .openai:
                    TextField("Base URL", text: $baseURL)
                    TextField(L("Modelo", "Model"), text: $openAIModel)
                    SecureField(L("API key (opcional)", "API key (optional)"), text: $apiKey)
                        .onSubmit { Keychain.apiKey = apiKey }
                        .onDisappear { Keychain.apiKey = apiKey }
                }
            } footer: {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: String {
        switch ProviderKind(rawValue: provider) ?? .claude {
        case .claude: L("Usa tu CLI `claude` con tu propia sesión. Inky nunca toca tus credenciales.",
                        "Runs your installed `claude` CLI with your own login. Inky never touches your credentials.")
        case .codex: L("Usa tu CLI `codex`. Más lento (~5 s por revisión).", "Runs your installed `codex` CLI. Slower (~5 s per request).")
        case .openai: L("Cualquier endpoint compatible con OpenAI: Ollama, LM Studio, OpenAI, OpenRouter.",
                        "Any OpenAI-compatible endpoint: Ollama, LM Studio, OpenAI, OpenRouter.")
        }
    }
}

private struct HistoryTab: View {
    @AppStorage(Prefs.historyEnabled) private var history = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $history) {
                    Text(L("Guardar las correcciones para repasarlas", "Save corrections to review later"))
                    Text(L("Solo en este Mac. Apagado por defecto.", "Only on this Mac. Off by default."))
                }
                HStack {
                    Button(L("Mostrar en Finder", "Show in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.fileURL])
                    }
                    Button(L("Borrar historial", "Clear history"), role: .destructive) { HistoryStore.clear() }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Shortcut recorder

/// Click, then press the new combination (needs ⌃, ⌥ or ⌘). Esc cancels.
struct ShortcutRecorder: View {
    @AppStorage(Prefs.hotkeyLabel) private var label = "⌃⌥I"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? L("Pulsa la combinación…", "Press the shortcut…") : label)
                .font(.system(size: 12, weight: .medium, design: recording ? .default : .rounded))
                .frame(minWidth: 120)
                .padding(.vertical, 3)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == kVK_Escape { stop(); return nil }
            let mods = e.modifierFlags.intersection([.control, .option, .command, .shift])
            guard !mods.intersection([.control, .option, .command]).isEmpty,
                  let key = e.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { NSSound.beep(); return nil }
            var flags: CGEventFlags = []
            var text = ""
            if mods.contains(.control) { flags.insert(.maskControl); text += "⌃" }
            if mods.contains(.option) { flags.insert(.maskAlternate); text += "⌥" }
            if mods.contains(.shift) { flags.insert(.maskShift); text += "⇧" }
            if mods.contains(.command) { flags.insert(.maskCommand); text += "⌘" }
            let names: [Int: String] = [kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥"]
            text += names[Int(e.keyCode)] ?? key
            let d = UserDefaults.standard
            d.set(Int(e.keyCode), forKey: Prefs.hotkeyCode)
            d.set(Int(flags.rawValue), forKey: Prefs.hotkeyMods)
            d.set(text, forKey: Prefs.hotkeyLabel)
            NotificationCenter.default.post(name: .inkyShortcutChanged, object: nil)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: Live privacy

@MainActor
enum LivePrivacy {
    /// Asks before turning live checking on: it sends what you type without pressing anything.
    static func confirm() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("¿Encender la revisión en vivo en Slack?", "Turn on live checking in Slack?")
        alert.informativeText = L("""
        Mientras esté encendida, cada oración que escribas en Slack se envía a tu proveedor de IA al hacer una pausa, \
        sin pulsar nada. Revisa que esto esté permitido por las políticas de tu empresa.

        La gota junto al campo de texto lleva un anillo mientras la revisión en vivo está encendida.
        """, """
        While it's on, every sentence you type in Slack is sent to your AI provider after you pause, \
        without pressing anything. Check that this is OK with your company's policies.

        The ink drop next to the text field shows a ring while live checking is on.
        """)
        alert.addButton(withTitle: L("Encender", "Turn On"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: LiveController.enabledKey)
        Metrics.record("live_toggled", ["on": on])
    }
}
