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
            statusLine(L("Revisando en vivo en Slack", "Live checking in Slack"), color: Ink.color(.clarity))
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
                Text(L("En vivo en Slack", "Live in Slack"))
                Text(L("Envía lo que escribes al hacer una pausa", "Sends what you type when you pause"))
                    .font(.caption).foregroundStyle(.secondary)
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
