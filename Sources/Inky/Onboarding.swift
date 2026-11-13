import AppKit
import InkyCore
import SwiftUI

/// First-run introduction: what Inky is, the Accessibility permission, the AI provider,
/// live checking (with what it implies) and the shortcut.
@MainActor
final class Onboarding {
    static let doneKey = "onboardingDone"
    private var window: NSWindow?
    var onFinish: () -> Void = {}

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() })
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 560, height: 600))
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window?.close()
        onFinish()
    }
}

private struct OnboardingView: View {
    var finish: () -> Void
    /// Debug: `--onboarding-step N` opens on step N.
    @State private var step = CommandLine.arguments.firstIndex(of: "--onboarding-step")
        .flatMap { i in CommandLine.arguments.dropFirst(i + 1).first.flatMap(Int.init) } ?? 0
    @State private var forward = true
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = Prefs.systemLanguage.rawValue
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            // Paper band with a small live demo of the step, under the (transparent) title bar.
            ZStack {
                Ink.paperTone
                hero.id(step).transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            .frame(height: 200)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }

            ZStack(alignment: .topLeading) {
                page.id(step)
                    .transition(.asymmetric(insertion: .offset(x: forward ? 24 : -24).combined(with: .opacity),
                                            removal: .offset(x: forward ? -24 : 24).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 40).padding(.top, 28)

            Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
            footer.padding(.horizontal, 24).frame(height: 64)
        }
        .frame(width: 560)
        .frame(maxHeight: .infinity)
        .background(.background)
        .ignoresSafeArea()
        .id(uiLanguage)
    }

    @ViewBuilder private var hero: some View {
        switch step {
        case 0: DemoSentence()
        case 1: PermissionHero()
        case 2: ProviderHero()
        case 3: LiveHero()
        default: KeysHero()
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: WelcomePage()
        case 1: PermissionPage()
        case 2: ProviderPage()
        case 3: LivePage()
        default: ReadyPage()
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule().fill(i == step ? Ink.ink : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .animation(Ink.pop, value: step)
            Spacer()
            if step > 0 {
                Button(L("Atrás", "Back")) { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 12)
            }
            Button { step == steps - 1 ? finish() : go(1) } label: {
                Text(step == steps - 1 ? L("Empezar", "Get started") : L("Siguiente", "Next"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.paper)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(Ink.ink, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(PressStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    private func go(_ d: Int) {
        forward = d > 0
        withAnimation(Ink.settle) { step = max(0, min(steps - 1, step + d)) }
    }
}

// MARK: Pages

private struct PageTitle: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 24, weight: .semibold, design: .serif))
            Text(subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = Prefs.systemLanguage.rawValue
    @AppStorage(Prefs.explanationLanguage) private var explanations = Prefs.systemLanguage.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: L("Hola, soy Inky", "Hi, I'm Inky"),
                      subtitle: L("Corrijo lo que escribes en cualquier app, te explico cada cambio y uso la IA que ya pagas: sin otra suscripción.",
                                  "I fix what you write in any app, explain every change, and use the AI you already pay for: no extra subscription."))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text(L("Idioma de Inky", "Inky's language")).foregroundStyle(.secondary)
                    languagePicker($uiLanguage)
                }
                GridRow {
                    Text(L("Explicaciones en", "Explanations in")).foregroundStyle(.secondary)
                    languagePicker($explanations)
                }
            }
            .font(.system(size: 13))
        }
    }

    private func languagePicker(_ value: Binding<String>) -> some View {
        Picker("", selection: value) {
            ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.nativeName).tag($0.rawValue) }
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 180)
    }
}

private struct PermissionPage: View {
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: L("Un permiso", "One permission"),
                      subtitle: L("Para leer el campo donde escribes y aplicar las correcciones, macOS me pide el permiso de Accesibilidad. Solo leo el campo cuando revisas, y nunca los de contraseña.",
                                  "To read the field you're typing in and apply fixes, macOS needs the Accessibility permission. I only read the field when you check, never password fields."))
            if trusted {
                Label(L("Permiso concedido", "Permission granted"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.color(.engagement))
                    .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                } label: {
                    Label(L("Abrir Ajustes del Sistema", "Open System Settings"), systemImage: "lock.open")
                }
                .controlSize(.large)
                Text(L("Activa «Inky» en Privacidad y seguridad → Accesibilidad. Esta pantalla se actualiza sola.",
                       "Turn on «Inky» in Privacy & Security → Accessibility. This screen updates by itself."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(Ink.pop, value: trusted)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }
}

private struct ProviderPage: View {
    @AppStorage(Prefs.provider) private var provider = ProviderKind.claude.rawValue
    @State private var hasClaude = CommandResolver.resolve("claude") != nil
    @State private var hasCodex = CommandResolver.resolve("codex") != nil

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: L("Tu IA", "Your AI"),
                      subtitle: L("Uso la herramienta que ya tienes instalada, con tu propia sesión. No instalo modelos ni toco tus credenciales.",
                                  "I use the tool you already have installed, with your own login. I don't install models or touch your credentials."))
            VStack(spacing: 8) {
                // Same shape for all three: where it runs · model · trade-off.
                option(.claude, "Claude Code",
                       hasClaude ? L("Encontrado · Claude Haiku · el más rápido y barato", "Found · Claude Haiku · fastest and cheapest")
                                 : L("No encontrado · instala la CLI `claude`", "Not found · install the `claude` CLI"),
                       hasClaude, recommended: true)
                option(.codex, "Codex",
                       hasCodex ? L("Encontrado · GPT-6 Luna · más lento, usa más tokens", "Found · GPT-6 Luna · slower, more tokens")
                                : L("No encontrado · instala la CLI `codex`", "Not found · install the `codex` CLI"),
                       hasCodex)
                option(.openai, L("API compatible con OpenAI", "OpenAI-compatible API"),
                       L("Ollama, LM Studio o API key · se configura en Ajustes", "Ollama, LM Studio or API key · set up in Settings"), true)
            }
        }
        .onAppear {
            if provider == ProviderKind.claude.rawValue, !hasClaude, hasCodex { provider = ProviderKind.codex.rawValue }
        }
    }

    private func option(_ kind: ProviderKind, _ title: String, _ detail: String, _ available: Bool, recommended: Bool = false) -> some View {
        let on = provider == kind.rawValue
        return Button { provider = kind.rawValue } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Ink.ink : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 14, weight: .medium))
                        if recommended && available {
                            Text(L("Recomendado", "Recommended"))
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary.opacity(0.7), in: Capsule())
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(on ? 0.25 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(available ? 1 : 0.5)
        .disabled(!available)
    }
}

private struct LivePage: View {
    @AppStorage(LiveController.enabledKey) private var enabled = false
    @AppStorage(Prefs.liveScope) private var scope = "list"
    @State private var apps: [String] = UserDefaults.standard.stringArray(forKey: Prefs.liveApps) ?? []
    @State private var picking = false

    private var current: String { enabled ? scope : "off" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: L("Revisión en vivo", "Live checking"),
                      subtitle: L("Subrayo errores mientras escribes. Es opcional.", "I underline mistakes as you type. It's optional."))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LivePrivacy.essentials(), id: \.text) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: row.symbol).font(.system(size: 13)).foregroundStyle(Ink.ink).frame(width: 16)
                        Text(row.text).font(.system(size: 12.5)).foregroundStyle(.primary.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(spacing: 6) {
                ChoiceCard(on: current == "off", title: L("Apagada", "Off"),
                           detail: Text(L("Solo reviso cuando pulsas tu atajo.", "I only check when you press your shortcut."))) { set("off") }
                // Clicking it again (or with no apps yet) opens the app picker.
                ChoiceCard(on: current == "list", title: L("En algunas apps", "In some apps"), detail: appsDetail) {
                    if current == "list" || apps.isEmpty { picking = true }
                    set("list")
                }
                .popover(isPresented: $picking, arrowEdge: .bottom) {
                    AppPicker(apps: $apps) { picking = false }
                }
                ChoiceCard(on: current == "all", title: L("En todas las apps", "In every app"),
                           detail: Text(L("Menos contraseñas, terminales y editores de código.", "Except passwords, terminals and code editors."))) { set("all") }
            }
        }
    }

    private var appsDetail: Text {
        let names = apps.compactMap(AppInfo.name)
        let list: String
        switch names.count {
        case 0: list = L("Elige las apps…", "Choose the apps…")
        case 1...3: list = ListFormatter.localizedString(byJoining: names)
        default: list = L("\(names[0]), \(names[1]) y \(names.count - 2) más", "\(names[0]), \(names[1]) and \(names.count - 2) more")
        }
        return Text(list) + Text(" · ") + Text(L("Cambiar…", "Change…")).foregroundColor(.primary).underline()
    }

    private func set(_ v: String) {
        withAnimation(Ink.settle) {
            if v == "off" { enabled = false } else { scope = v; enabled = true }
        }
        Metrics.record("live_toggled", ["on": v != "off", "from": "onboarding", "scope": v])
    }
}

/// A selectable card with a radio, like the provider choices.
private struct ChoiceCard: View {
    var on: Bool
    var title: String
    var detail: Text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Ink.ink : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
                    detail.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(on ? 0.25 : 0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "¿Dónde reviso?": app chips in two columns, plus Other….
private struct AppPicker: View {
    @Binding var apps: [String]
    var done: () -> Void
    @State private var extra: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("¿Dónde reviso?", "Where should I check?")).font(.system(size: 13, weight: .semibold))
            let candidates = AppInfo.writingApps() + (apps + extra).filter { !AppInfo.writingApps().contains($0) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(Array(Set(candidates)).sorted { (AppInfo.name($0) ?? $0) < (AppInfo.name($1) ?? $1) }, id: \.self) { id in
                    let on = apps.contains(id)
                    Button { toggle(id) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: AppInfo.icon(id)).resizable().frame(width: 16, height: 16)
                            Text(AppInfo.name(id) ?? id).lineLimit(1)
                            Spacer(minLength: 0)
                            if on { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(on ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(on ? 0.3 : 0.1)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button(L("Otra…", "Other…")) {
                    if let id = AppInfo.choose(), !Prefs.neverLive.contains(id) { extra.append(id); if !apps.contains(id) { toggle(id) } }
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                Spacer()
                Button(L("Listo", "Done"), action: done).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func toggle(_ id: String) {
        if let i = apps.firstIndex(of: id) { apps.remove(at: i) } else { apps.append(id) }
        UserDefaults.standard.set(apps, forKey: Prefs.liveApps)
    }
}

private struct ReadyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageTitle(title: L("Listo", "All set"),
                      subtitle: L("Escribe en cualquier campo de texto y pulsa tu atajo. Te muestro el texto corregido y por qué cambió cada cosa.",
                                  "Type in any text field and press your shortcut. I'll show the corrected text and why each thing changed."))
            HStack(spacing: 12) {
                Text(L("Revisar texto", "Check text")).font(.system(size: 14))
                ShortcutRecorder()
            }
            Label(L("Estoy en la barra de menús, junto al reloj: la «i». Desde ahí enciendes o apagas la revisión en vivo.",
                    "I live in the menu bar, next to the clock: the «i». Turn live checking on or off from there."), systemImage: "menubar.arrow.up.rectangle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

// MARK: Heroes (small looping demos on the paper band)

/// "can you ~sent~ send me the file?": the underline draws, then the word is rewritten in ink.
private struct DemoSentence: View {
    @State private var drawn: CGFloat = 0
    @State private var fixed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            Brand.mark(22).foregroundStyle(Ink.paper)
                .frame(width: 44, height: 44)
                .background(Ink.ink, in: RoundedRectangle(cornerRadius: 11))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
            HStack(spacing: 0) {
                Text("can you ")
                ZStack {
                    Text("sent").opacity(fixed ? 0 : 1).blur(radius: fixed ? 3 : 0)
                    Text("send").fontWeight(.semibold).opacity(fixed ? 1 : 0).blur(radius: fixed ? 0 : 3)
                }
                .overlay(alignment: .bottom) {
                    WaveLine().trim(from: 0, to: drawn).stroke(Ink.color(.correctness), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                        .frame(height: 5).offset(y: 5).opacity(fixed ? 0 : 1)
                }
                Text(" me the file?")
            }
            .font(.system(size: 24, design: .serif))
            .foregroundStyle(.primary)
        }
        .task { await loop() }
    }

    private func loop() async {
        if reduceMotion { drawn = 1; return }
        while !Task.isCancelled {
            drawn = 0; fixed = false
            try? await Task.sleep(for: .seconds(0.8))
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)) { drawn = 1 }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Ink.settle) { fixed = true }
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.3)) { fixed = false; drawn = 0 }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }
}

struct WaveLine: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let y = r.midY
        p.move(to: CGPoint(x: r.minX, y: y))
        var x = r.minX, up = true
        while x < r.maxX {
            let nx = min(x + 4, r.maxX)
            p.addQuadCurve(to: CGPoint(x: nx, y: y), control: CGPoint(x: (x + nx) / 2, y: y + (up ? -2.5 : 2.5)))
            x = nx; up.toggle()
        }
        return p
    }
}

/// A System Settings-style row whose switch turns on (or shows the real state).
private struct PermissionHero: View {
    @State private var on = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inky").font(.system(size: 14, weight: .medium))
                Text(L("Accesibilidad", "Accessibility")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Capsule().fill(on ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 38, height: 22)
                .overlay(alignment: on ? .trailing : .leading) {
                    Circle().fill(.white).padding(2).shadow(radius: 1, y: 1)
                }
        }
        .padding(14)
        .frame(width: 300)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
        .animation(Ink.pop, value: on)
        .onReceive(timer) { _ in on = AXIsProcessTrusted() }
    }
}

/// Terminal-style chips for the CLIs found on this Mac.
private struct ProviderHero: View {
    private let found: [(String, Bool)] = [("claude", CommandResolver.resolve("claude") != nil),
                                           ("codex", CommandResolver.resolve("codex") != nil)]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(found, id: \.0) { name, ok in
                HStack(spacing: 10) {
                    Text("$").foregroundStyle(.tertiary)
                    Text(name).fontWeight(.medium)
                    Spacer()
                    Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(ok ? Ink.color(.engagement) : .secondary)
                }
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(width: 260)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
            }
        }
    }
}

/// A tiny composer: the drop breathes, then an underline is drawn under a word.
private struct LiveHero: View {
    @State private var checking = false
    @State private var drawn: CGFloat = 0

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(checking ? Ink.ink : Ink.color(.correctness)).frame(width: 20, height: 20)
                .overlay {
                    if checking { Brand.mark(11).foregroundStyle(Ink.paper) }
                    else { Text("1").font(.system(size: 11, weight: .bold)).foregroundStyle(Ink.onColor) }
                }
                .scaleEffect(checking ? 1.1 : 1)
                .overlay { Circle().strokeBorder(Ink.ink, lineWidth: 1.5).frame(width: 27, height: 27).opacity(checking ? 0 : 0.6) }
            HStack(spacing: 0) {
                Text("I am ")
                Text("agree")
                    .overlay(alignment: .bottom) {
                        WaveLine().trim(from: 0, to: drawn).stroke(Ink.color(.correctness), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                            .frame(height: 5).offset(y: 5)
                    }
                Text(" with the plan")
            }
            .font(.system(size: 15))
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(width: 280, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)))
        }
        .task {
            while !Task.isCancelled {
                drawn = 0
                withAnimation(.easeInOut(duration: 0.5).repeatCount(3, autoreverses: true)) { checking = true }
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(Ink.pop) { checking = false }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)) { drawn = 1 }
                try? await Task.sleep(for: .seconds(2.6))
            }
        }
    }
}

/// The shortcut as keycaps that press one after another.
private struct KeysHero: View {
    @State private var pressed = -1
    private var keys: [String] { Prefs.shortcut.map(String.init) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(keys.enumerated()), id: \.offset) { i, k in
                Text(k)
                    .font(.system(size: 26, weight: .medium, design: .rounded))
                    .frame(width: 62, height: 62)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(pressed >= i ? 0.04 : 0.16), radius: pressed >= i ? 1 : 6, y: pressed >= i ? 1 : 4)
                    .scaleEffect(pressed >= i ? 0.93 : 1)
            }
        }
        .task {
            while !Task.isCancelled {
                for i in keys.indices {
                    try? await Task.sleep(for: .seconds(0.35))
                    withAnimation(Ink.pop) { pressed = i }
                }
                try? await Task.sleep(for: .seconds(1.0))
                withAnimation(Ink.pop) { pressed = -1 }
                try? await Task.sleep(for: .seconds(0.8))
            }
        }
    }
}
