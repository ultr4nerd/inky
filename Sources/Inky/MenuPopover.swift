import AppKit
import InkyCore
import SwiftUI

/// What the menu-bar popover shows. Refreshed every time it opens.
@MainActor
final class MenuModel: ObservableObject {
    @Published var trusted = true
    @Published var hotkeyOK = true
    @Published var shortcut = "⌃⌥I"
    @Published var liveOn = false
    @Published var applied = 0          // fixes applied in the last 7 days (panel + live)
    @Published var liveShown = 0        // live suggestions shown
    @Published var liveApplied = 0
    @Published var usage: UsageReport?
    @Published var provider: ProviderKind = .claude
    @Published var liveWhere = "Slack"

    var onCheck: () -> Void = {}
    var onToggleLive: (Bool) -> Void = { _ in }
    var onStats: () -> Void = {}
    var onSettings: () -> Void = {}
    var onGrant: () -> Void = {}

    func refreshStats() {
        let ev = Metrics.events(since: Date().addingTimeInterval(-7 * 86400))
        func of(_ e: String) -> [[String: Any]] { ev.filter { $0["event"] as? String == e } }
        liveApplied = of("suggestion_applied").count
        liveShown = of("live_check").reduce(0) { $0 + ($1["edits"] as? Int ?? 0) }
        applied = liveApplied + of("panel_applied").reduce(0) { $0 + ($1["edits"] as? Int ?? 0) }
    }
}

struct MenuPopoverView: View {
    @ObservedObject var model: MenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                MenuRow(action: model.onCheck) {
                    Image(systemName: "text.magnifyingglass").frame(width: 18)
                    Text(L("Revisar texto", "Check text"))
                    Spacer()
                    KeyChip(text: model.shortcut)
                }
                .disabled(!model.trusted)
                liveRow
            }
            .padding(6)
            Divider().padding(.horizontal, 10)
            stats.padding(.horizontal, 14).padding(.vertical, 10)
            Divider().padding(.horizontal, 10)
            // Only Claude reports subscription limits; for the others there's nothing to show.
            if model.provider == .claude {
                UsageSummary(usage: model.usage, provider: model.provider)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Divider().padding(.horizontal, 10)
            }
            VStack(spacing: 2) {
                MenuRow(action: model.onSettings) {
                    Image(systemName: "gearshape").frame(width: 18)
                    Text(L("Ajustes…", "Settings…"))
                    Spacer()
                    KeyChip(text: "⌘,")
                }
                .keyboardShortcut(",", modifiers: .command)
                MenuRow(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "power").frame(width: 18)
                    Text(L("Salir de Inky", "Quit Inky"))
                    Spacer()
                    KeyChip(text: "⌘Q")
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(6)
        }
        .frame(width: 290)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Brand.mark(16)
                .foregroundStyle(Ink.paper)
                .frame(width: 30, height: 30)
                .background(Ink.ink, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Inky").font(.system(size: 15, weight: .semibold, design: .serif))
                status
            }
            Spacer()
        }
    }

    @ViewBuilder private var status: some View {
        if !model.trusted {
            Button(action: model.onGrant) {
                statusLine(L("Falta el permiso de Accesibilidad", "Accessibility permission needed"), color: Ink.color(.correctness))
            }
            .buttonStyle(.plain)
        } else if !model.hotkeyOK {
            statusLine(L("El atajo \(model.shortcut) está ocupado", "Shortcut \(model.shortcut) is taken"), color: Ink.color(.correctness))
        } else if model.liveOn {
            statusLine(L("Revisando en vivo en \(model.liveWhere)", "Live checking in \(model.liveWhere)"), color: Ink.color(.clarity))
        } else {
            statusLine(L("Listo", "Ready"), color: Ink.color(.engagement))
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var liveRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform").frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("En vivo en \(model.liveWhere)", "Live in \(model.liveWhere)"))
                Text(L("Envía lo que escribes al hacer una pausa", "Sends what you type when you pause"))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { model.liveOn }, set: { model.onToggleLive($0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("Últimos 7 días", "Last 7 days")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Detalle", "Details"), action: model.onStats)
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                stat("\(model.applied)", L("correcciones aplicadas", "fixes applied"))
                if model.liveShown > 0 {
                    stat("\(Int((Double(model.liveApplied) / Double(model.liveShown) * 100).rounded()))%",
                         L("aceptadas en vivo", "accepted live"))
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 22, weight: .semibold, design: .serif)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// A full-width menu row that highlights on hover, like a native menu item.
private struct MenuRow<Content: View>: View {
    var action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
    }
}

private struct KeyChip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// "Claude · weekly limit" with a bar: the whole account's usage, and Inky's slice in ink.
struct UsageSummary: View {
    var usage: UsageReport?
    var provider: ProviderKind

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch provider {
            case .claude:
                if let u = usage {
                    HStack {
                        Text(L("Tu suscripción de Claude", "Your Claude subscription")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(L("se reinicia \(u.resetText)", "resets \(u.resetText)")).font(.caption).foregroundStyle(.tertiary)
                    }
                    bar(total: u.window.utilization, inky: u.inkyShare)
                    HStack(spacing: 4) {
                        Text(UsageReport.pct(u.window.utilization)).monospacedDigit().fontWeight(.medium)
                        Text(L("del \(u.windowName) usado", "of your \(u.windowName) used")).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(Ink.ink).frame(width: 8, height: 8)
                        Text(L("Inky: \(UsageReport.approx(u.inkyShare)) · \(u.inkyRequests) revisiones",
                               "Inky: \(UsageReport.approx(u.inkyShare)) · \(u.inkyRequests) checks"))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .help(L("Estimado con el uso de Claude Code en este Mac. Si también usas claude.ai, el número real de Inky es menor.",
                            "Estimated from Claude Code usage on this Mac. If you also use claude.ai, Inky's real share is lower."))
                } else {
                    Text(L("Tu suscripción de Claude", "Your Claude subscription")).font(.caption).foregroundStyle(.secondary)
                    Text(L("Haz una revisión para ver cuánto de tu límite usa Inky.", "Run a check to see how much of your limit Inky uses."))
                        .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            case .codex:
                Text("Codex").font(.caption).foregroundStyle(.secondary)
                Text(L("Codex no informa de tus límites. Cada revisión usa ~10 000 tokens (unas 2–3× más que Claude) y tarda ~4 s.",
                       "Codex doesn't report your limits. Each check uses ~10,000 tokens (about 2–3× Claude) and takes ~4 s."))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            case .openai:
                Text(L("API compatible con OpenAI", "OpenAI-compatible API")).font(.caption).foregroundStyle(.secondary)
                Text(L("Se cobra por token según tu proveedor. Inky usa unos 1 000–4 000 tokens por revisión.",
                       "Billed per token by your provider. Inky uses about 1,000–4,000 tokens per check."))
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func bar(total: Double, inky: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.secondary.opacity(0.55)).frame(width: max(2, g.size.width * min(1, total)))
                Capsule().fill(Ink.ink).frame(width: inky > 0 ? max(3, g.size.width * min(1, inky)) : 0)
            }
        }
        .frame(height: 6)
    }
}
