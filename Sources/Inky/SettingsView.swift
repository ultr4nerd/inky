import AppKit
import Carbon.HIToolbox
import InkyCore
import SwiftUI

extension Notification.Name {
    /// Posted when the user records a new global shortcut.
    static let inkyShortcutChanged = Notification.Name("inkyShortcutChanged")
    static let inkyShowOnboarding = Notification.Name("inkyShowOnboarding")
}

/// The Settings window: native toolbar tabs (like System Settings-era Preferences), each tab
/// a SwiftUI form. The window resizes to each tab.
@MainActor
enum SettingsWindow {
    static func make() -> NSWindow {
        let tabs = TitledTabs()
        tabs.tabStyle = .toolbar
        tabs.tabViewItems = [
            item(GeneralTab(), L("General", "General"), "gearshape"),
            item(LiveTab(), L("En vivo", "Live"), "waveform"),
            item(ToneTab(), L("Tono", "Tone"), "text.bubble"),
            item(ProviderTab(), L("Proveedor", "Provider"), "cpu"),
            item(HistoryTab(), L("Historial", "History"), "clock.arrow.circlepath"),
        ]
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.title = tabs.tabViewItems.first?.label ?? "Inky"
        return w
    }

    /// Shows the selected tab's name as the window title.
    private final class TitledTabs: NSTabViewController {
        override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
            super.tabView(tabView, didSelect: item)
            view.window?.title = item?.label ?? "Inky"
        }
    }

    private static func item<V: View>(_ view: V, _ title: String, _ symbol: String) -> NSTabViewItem {
        let host = NSHostingController(rootView: Localized { view }.frame(width: 500))
        host.sizingOptions = .preferredContentSize
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
}

/// Rebuilds its content when the interface language changes, so every L() string updates.
private struct Localized<Content: View>: View {
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = ExplanationLanguage.spanish.rawValue
    @ViewBuilder var content: Content
    var body: some View { content.id(uiLanguage) }
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
            Section {
                Button(L("Ver la introducción otra vez", "Show the introduction again")) {
                    NotificationCenter.default.post(name: .inkyShowOnboarding, object: nil)
                }
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
                Toggle(L("Revisión en vivo", "Live checking"), isOn: Binding(get: { enabled }, set: { on in
                    if !on || LivePrivacy.confirm() { LivePrivacy.set(on) }
                }))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(LivePrivacy.implications(), id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Dónde", "Where")) {
                LiveAppsEditor()
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
    /// What turning live checking on means, in plain words (Settings, the alert, onboarding).
    /// `where` nil: generic wording ("the apps you choose"), for before a choice is made.
    static func implications() -> [String] { implications(where: Prefs.liveWhere) }

    static func implications(where place: String?) -> [String] {
        let provider = ProviderKind(rawValue: UserDefaults.standard.string(forKey: Prefs.provider) ?? "") ?? .claude
        var cost: String
        switch provider {
        case .claude:
            if let u = Usage.last, u.perRequest > 0 {
                cost = L("Consume tu suscripción de Claude: cada revisión usa \(UsageReport.approx(u.perRequest)) de tu \(u.windowName). Esta semana Inky lleva \(UsageReport.approx(u.inkyShare)) (\(u.inkyRequests) revisiones).",
                         "Uses your Claude subscription: each check takes \(UsageReport.approx(u.perRequest)) of your \(u.windowName). This week Inky is at \(UsageReport.approx(u.inkyShare)) (\(u.inkyRequests) checks).")
            } else {
                cost = L("Consume tu suscripción de Claude. Con Haiku es poco: unas 100 revisiones suelen ser menos del 0.01% del límite semanal.",
                         "Uses your Claude subscription. With Haiku it's little: about 100 checks are usually under 0.01% of the weekly limit.")
            }
        case .codex:
            cost = L("Con Codex cada revisión usa ~19 000 tokens: tu límite se gasta unas 5× más rápido que con Claude.",
                     "With Codex each check uses ~19,000 tokens: your limit runs out about 5× faster than with Claude.")
        case .openai:
            cost = L("Tu proveedor cobra cada revisión (unos 1 000–4 000 tokens).", "Your provider bills each check (about 1,000–4,000 tokens).")
        }
        return [
            place.map { p in L("Envía lo que escribes en \(p) a tu proveedor de IA cada vez que haces una pausa, sin pulsar nada.",
                               "Sends what you type in \(p) to your AI provider every time you pause, without pressing anything.") }
                ?? L("Envía lo que escribes en las apps que elijas a tu proveedor de IA cada vez que haces una pausa, sin pulsar nada.",
                     "Sends what you type in the apps you choose to your AI provider every time you pause, without pressing anything."),
            cost,
            L("Nunca revisa contraseñas, terminales, gestores de contraseñas ni las apps que bloquees.",
              "Never checks passwords, terminals, password managers or the apps you block."),
            L("La gota junto al campo lleva un anillo mientras está encendida. Se apaga desde la «i» de la barra de menús.",
              "The drop next to the field shows a ring while it's on. Turn it off from the «i» in the menu bar."),
        ]
    }

    /// Asks before turning live checking on: it sends what you type without pressing anything.
    static func confirm() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("¿Encender la revisión en vivo en \(Prefs.liveWhere)?", "Turn on live checking in \(Prefs.liveWhere)?")
        alert.informativeText = implications().map { "• " + $0 }.joined(separator: "\n\n")
            + L("\n\nRevisa que esté permitido por las políticas de tu empresa.", "\n\nCheck that this is OK with your company's policies.")
        alert.addButton(withTitle: L("Encender", "Turn On"))
        alert.addButton(withTitle: L("Cancelar", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: LiveController.enabledKey)
        Metrics.record("live_toggled", ["on": on])
    }
}

/// "Only in these apps" / "In every app except", with the list and an Add menu.
private struct LiveAppsEditor: View {
    @AppStorage(Prefs.liveScope) private var scope = "list"
    @State private var apps: [String] = []

    private var key: String { scope == "all" ? Prefs.liveBlocked : Prefs.liveApps }

    var body: some View {
        Picker("", selection: $scope) {
            Text(L("Solo en estas apps", "Only in these apps")).tag("list")
            Text(L("En todas, excepto", "Everywhere except")).tag("all")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: scope, initial: true) { _, _ in load() }

        ForEach(apps, id: \.self) { id in
            HStack(spacing: 8) {
                Image(nsImage: AppInfo.icon(id)).resizable().frame(width: 18, height: 18)
                Text(AppInfo.name(id) ?? id)
                Spacer()
                Button { apps.removeAll { $0 == id }; save() } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L("Quitar", "Remove"))
            }
        }
        if apps.isEmpty {
            Text(scope == "all" ? L("Ninguna app bloqueada.", "No blocked apps.") : L("Ninguna app: la revisión en vivo no correrá.", "No apps: live checking won't run."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Menu(scope == "all" ? L("Bloquear una app…", "Block an app…") : L("Agregar una app…", "Add an app…")) {
            ForEach(AppInfo.running().filter { !apps.contains($0.id) && !Prefs.neverLive.contains($0.id) }, id: \.id) { app in
                Button(app.name) { add(app.id) }
            }
            Divider()
            Button(L("Otra…", "Other…")) { if let id = AppInfo.choose() { add(id) } }
        }
        .fixedSize()
    }

    private func load() { apps = UserDefaults.standard.stringArray(forKey: key) ?? [] }
    private func save() { UserDefaults.standard.set(apps, forKey: key) }
    private func add(_ id: String) {
        guard !apps.contains(id), !Prefs.neverLive.contains(id) else { return }
        apps.append(id); save()
    }
}
