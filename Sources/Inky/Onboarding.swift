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
            w.setContentSize(NSSize(width: 520, height: 470))
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
    @State private var step = 0
    @State private var forward = true
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = Prefs.systemLanguage.rawValue
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page.id(step)
                    .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.top, 44)
            .clipped()
            footer.padding(.horizontal, 24).padding(.vertical, 18)
        }
        .frame(width: 520, height: 470)
        .background(.background)
        .id(uiLanguage)
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
                Button(L("Atrás", "Back")) { go(-1) }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 10)
            }
            Button { step == steps - 1 ? finish() : go(1) } label: {
                Text(step == steps - 1 ? L("Empezar", "Get started") : L("Siguiente", "Next"))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Ink.paper)
                    .padding(.horizontal, 16).padding(.vertical, 7)
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
            Text(title).font(.system(size: 26, weight: .semibold, design: .serif))
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    @AppStorage(Prefs.uiLanguage) private var uiLanguage = Prefs.systemLanguage.rawValue
    @AppStorage(Prefs.explanationLanguage) private var explanations = Prefs.systemLanguage.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Brand.mark(30).foregroundStyle(Ink.paper)
                .frame(width: 56, height: 56)
                .background(Ink.ink, in: RoundedRectangle(cornerRadius: 14))
            PageTitle(title: L("Hola, soy Inky", "Hi, I'm Inky"),
                      subtitle: L("Corrijo lo que escribes en cualquier app, te explico cada cambio y uso la IA que ya pagas: sin otra suscripción.",
                                  "I fix what you write in any app, explain every change, and use the AI you already pay for: no extra subscription."))
            VStack(alignment: .leading, spacing: 10) {
                Picker(L("Idioma de Inky", "Inky's language"), selection: $uiLanguage) {
                    ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.nativeName).tag($0.rawValue) }
                }
                Picker(L("Explicar las correcciones en", "Explain corrections in"), selection: $explanations) {
                    ForEach(ExplanationLanguage.allCases, id: \.rawValue) { Text($0.nativeName).tag($0.rawValue) }
                }
            }
            .frame(maxWidth: 360)
        }
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
                option(.claude, L("Claude Code", "Claude Code"), hasClaude ? L("Encontrado · recomendado (rápido y barato con Haiku)", "Found · recommended (fast and cheap with Haiku)")
                                                                           : L("No encontrado: instala `claude` para usarlo", "Not found: install `claude` to use it"), hasClaude)
                option(.codex, "Codex", hasCodex ? L("Encontrado · más lento y ~5× más tokens por revisión", "Found · slower, ~5× more tokens per check")
                                                 : L("No encontrado", "Not found"), hasCodex)
                option(.openai, L("API compatible con OpenAI", "OpenAI-compatible API"), L("Ollama, LM Studio o una API key · se configura en Ajustes", "Ollama, LM Studio or an API key · set up in Settings"), true)
            }
        }
        .onAppear {
            if provider == ProviderKind.claude.rawValue, !hasClaude, hasCodex { provider = ProviderKind.codex.rawValue }
        }
    }

    private func option(_ kind: ProviderKind, _ title: String, _ detail: String, _ available: Bool) -> some View {
        let on = provider == kind.rawValue
        return Button { provider = kind.rawValue } label: {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Ink.ink : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .medium))
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

    private var choice: Binding<String> {
        Binding(get: { enabled ? scope : "off" }, set: { v in
            if v == "off" { enabled = false; return }
            scope = v
            if v == "list" { UserDefaults.standard.set(["com.tinyspeck.slackmacgap"], forKey: Prefs.liveApps) }
            enabled = true
            Metrics.record("live_toggled", ["on": true, "from": "onboarding"])
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: L("Revisión en vivo", "Live checking"),
                      subtitle: L("Puedo subrayar errores mientras escribes, sin que pulses nada. Antes de decidir, esto es lo que implica:",
                                  "I can underline mistakes as you type, without pressing anything. Before you decide, here's what it means:"))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(LivePrivacy.implications(), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(line).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("", selection: choice) {
                Text(L("Apagada", "Off")).tag("off")
                Text(L("Solo Slack", "Slack only")).tag("list")
                Text(L("Todas las apps", "Every app")).tag("all")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            Text(L("Se cambia cuando quieras desde la «i» de la barra de menús o en Ajustes.", "Change it anytime from the «i» in the menu bar or in Settings."))
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct ReadyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(title: L("Listo", "All set"),
                      subtitle: L("Escribe en cualquier campo de texto y pulsa tu atajo. Te muestro el texto corregido y por qué cambió cada cosa.",
                                  "Type in any text field and press your shortcut. I'll show the corrected text and why each thing changed."))
            HStack(spacing: 12) {
                Text(L("Revisar texto", "Check text")).font(.system(size: 14))
                ShortcutRecorder()
            }
            Label(L("Estoy en la barra de menús, junto al reloj: la «i».", "I live in the menu bar, next to the clock: the «i»."), systemImage: "menubar.arrow.up.rectangle")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}
