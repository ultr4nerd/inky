import AppKit
import Combine
import InkyCore
import SwiftUI

@MainActor
final class PanelModel: ObservableObject {
    enum State: Equatable { case loading, result, noChanges, error(String) }

    @Published var state: State = .loading
    @Published var mode: Mode = .correct
    @Published var tone: Tone = .neutral
    @Published var providerName = ""
    @Published var appName = ""
    @Published var showExplanations = true
    @Published var language: ExplanationLanguage = .spanish
    @Published var original = ""
    @Published var edits: [PlannedEdit] = []   // relative to `original`
    /// How the original text sounds, from the model.
    @Published var detectedTone: String?
    /// Edit (by range location) under the mouse, in the panel or over the field.
    @Published var hovered: Int?
    @Published var showCustom = false
    @Published var customInstruction = ""

    var onApply: () -> Void = {}
    var onCancel: () -> Void = {}
    var onMode: (Mode) -> Void = { _ in }
    var onHover: (Int?) -> Void = { _ in }

    /// UI strings follow the explanation language.
    func t(_ es: String, _ en: String) -> String { language == .spanish ? es : en }

    func title(_ m: Mode) -> String {
        switch m {
        case .correct: t("Corregir", "Correct")
        case .natural: t("Natural", "Natural")
        case .translate: t("Traducir", "Translate")
        case .shorter: t("Más corto", "Shorter")
        case .formal: t("Más formal", "More formal")
        case .friendly: t("Más amigable", "Friendlier")
        case .direct: t("Más directo", "More direct")
        case .simpler: t("Más simple", "Simpler")
        case .custom: t("Personalizado", "Custom")
        }
    }

    func label(_ c: EditCategory) -> String {
        switch c {
        case .correctness: t("Corrección", "Correctness")
        case .clarity: t("Claridad", "Clarity")
        case .engagement: t("Interés", "Engagement")
        case .tone: t("Tono", "Tone")
        }
    }
}

/// Inky's visual language: one ink accent for the UI, and a color per kind of suggestion.
enum Ink {
    static let accent = Color(red: 0.31, green: 0.49, blue: 1.0)

    static func nsColor(_ c: EditCategory) -> NSColor {
        switch c {
        case .correctness: NSColor(red: 0.96, green: 0.36, blue: 0.38, alpha: 1)
        case .clarity: NSColor(red: 0.31, green: 0.49, blue: 1.0, alpha: 1)
        case .engagement: NSColor(red: 0.20, green: 0.74, blue: 0.47, alpha: 1)
        case .tone: NSColor(red: 0.66, green: 0.45, blue: 0.98, alpha: 1)
        }
    }

    static func color(_ c: EditCategory) -> Color { Color(nsColor: nsColor(c)) }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var customFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.showCustom { customField }
            content
            footer
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
        .background { background }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)) }
        .animation(.smooth(duration: 0.22), value: model.state)
        .animation(.smooth(duration: 0.18), value: model.showExplanations)
        .animation(.smooth(duration: 0.18), value: model.showCustom)
        .onChange(of: model.showCustom) { _, show in customFocused = show }
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16).fill(.regularMaterial)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Ink.accent, in: RoundedRectangle(cornerRadius: 6))
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            modePicker
        }
    }

    private var subtitle: String {
        let where_ = model.appName.isEmpty ? "" : " · \(model.appName)"
        switch model.state {
        case .loading: return model.t("Revisando…", "Checking…") + where_
        case .result:
            if !model.mode.isPrimary { return model.title(model.mode) + where_ }
            let n = model.edits.count
            return (n == 1 ? model.t("1 corrección", "1 fix") : model.t("\(n) correcciones", "\(n) fixes")) + where_
        case .noChanges: return model.t("Sin cambios", "No changes") + where_
        case .error: return "Inky" + where_
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(Mode.primary, id: \.self) { m in pill(model.title(m), on: m == model.mode) { model.onMode(m) } }
            Menu {
                ForEach(Mode.rewrites, id: \.self) { m in Button(model.title(m)) { model.onMode(m) } }
                Divider()
                Button(model.t("Pedir algo…  ⌘K", "Ask for something…  ⌘K")) { model.showCustom = true }
            } label: {
                pillLabel(model.mode.isPrimary ? model.t("Reescribir", "Rewrite") : model.title(model.mode),
                          on: !model.mode.isPrimary, chevron: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(2)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, on: on, chevron: false) }.buttonStyle(.plain)
    }

    private func pillLabel(_ title: String, on: Bool, chevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title)
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .font(.caption.weight(on ? .semibold : .regular))
        .foregroundStyle(on ? .primary : .secondary)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.9))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var customField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Ink.accent)
            TextField(model.t("Ej. que suene menos agresivo", "e.g. make it sound less pushy"), text: $model.customInstruction)
                .textFieldStyle(.plain)
                .focused($customFocused)
                .onSubmit {
                    guard !model.customInstruction.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    model.showCustom = false
                    model.onMode(.custom)
                }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            HStack(alignment: .top, spacing: 10) {
                ProgressView().controlSize(.small)
                Text(model.original).font(.system(size: 15)).foregroundStyle(.tertiary).lineLimit(4)
            }
            .transition(.opacity)
        case .noChanges:
            VStack(alignment: .leading, spacing: 6) {
                Label(model.t("Se ve bien", "Looks good"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.accent)
                toneLine
            }
            .transition(.opacity)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .result:
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(corrected)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)

                toneLine

                if model.showExplanations {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(sortedEdits, id: \.range.location) { e in note(e) }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder private var toneLine: some View {
        if let tone = model.detectedTone, !tone.isEmpty, model.mode.isPrimary {
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold))
                Text(model.t("Suena", "Sounds")).fontWeight(.medium)
                Text(tone)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func note(_ e: PlannedEdit) -> some View {
        let color = Ink.color(e.category)
        let hovered = model.hovered == e.range.location
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(color.opacity(0.85)).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if model.mode.isPrimary {
                        (Text(removed(e)).strikethrough().foregroundStyle(.secondary)
                         + Text("  →  ").foregroundStyle(.tertiary)
                         + Text(e.replacement.isEmpty ? "∅" : e.replacement).bold())
                            .font(.system(size: 13))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Text(model.label(e.category).uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                }
                if !e.explanation.isEmpty {
                    Text(e.explanation)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(6)
        .background(hovered ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { inside in
            model.hovered = inside ? e.range.location : (model.hovered == e.range.location ? nil : model.hovered)
            model.onHover(model.hovered)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6) {
            key("⇥"); hint(model.t("modo", "mode"))
            key("⌘K").padding(.leading, 6); hint(model.t("pedir algo", "ask"))
            if case .result = model.state {
                key("⌘E").padding(.leading, 6)
                hint(model.showExplanations ? model.t("ocultar notas", "hide notes") : model.t("ver notas", "show notes"))
            }
            Spacer()
            Button("Esc") { model.onCancel() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            if case .result = model.state {
                Button { model.onApply() } label: {
                    Text(model.t("Aplicar ↩", "Apply ↩"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Ink.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func hint(_ s: String) -> some View { Text(s).font(.caption2).foregroundStyle(.tertiary) }

    private func key(_ k: String) -> some View {
        Text(k).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
    }

    // MARK: Text

    private var sortedEdits: [PlannedEdit] { model.edits.sorted { $0.range.location < $1.range.location } }

    private func removed(_ e: PlannedEdit) -> String { (model.original as NSString).substring(with: e.range) }

    /// The corrected text, each change highlighted in its category color.
    private var corrected: AttributedString {
        let ns = model.original as NSString
        var out = AttributedString()
        var cursor = 0
        for e in sortedEdits {
            out += AttributedString(ns.substring(with: NSRange(location: cursor, length: e.range.location - cursor)))
            var ins = AttributedString(e.replacement)
            if model.mode.isPrimary {
                let c = Ink.color(e.category)
                ins.backgroundColor = c.opacity(model.hovered == e.range.location ? 0.32 : 0.16)
                ins.underlineStyle = Text.LineStyle(pattern: .solid, color: c)
            }
            out += ins
            cursor = NSMaxRange(e.range)
        }
        out += AttributedString(ns.substring(from: cursor))
        return out
    }
}

/// Floating panel that takes keyboard input without activating Inky.
final class InkyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    let model = PanelModel()
    private let panel: InkyPanel
    private let host: NSHostingView<PanelView>
    /// Off-screen copy used only to measure the SwiftUI content.
    private lazy var measurer = NSHostingController(rootView: PanelView(model: model))
    private var keyMonitor: Any?
    private var changes: AnyCancellable?
    /// Above the field the panel grows upwards (bottom edge fixed); below it grows down.
    private var growsUp = true

    var onKey: ((NSEvent) -> Bool)?
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = InkyPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        host = NSHostingView(rootView: PanelView(model: model))
        host.sizingOptions = [] // we size the panel ourselves (otherwise it grows downwards, under the Dock)
        panel.contentView = host
        // Content changes size (loading → result), so resize the panel to fit each time.
        changes = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeToFit() }
        }
    }

    private func contentSize() -> NSSize {
        let fit = measurer.sizeThatFits(in: NSSize(width: 460, height: 2000))
        return NSSize(width: 460, height: max(ceil(fit.height), 70))
    }

    private func resizeToFit() {
        guard panel.isVisible else { return }
        let size = contentSize()
        var frame = panel.frame
        if !growsUp { frame.origin.y += frame.height - size.height }
        frame.size = size
        panel.setFrame(frame, display: true, animate: false)
    }

    /// `anchor` is in AX coordinates (top-left origin). The panel goes above the field
    /// (Slack's composer sits at the bottom of the window), or below if there's no room.
    func show(anchor: CGRect?) {
        let size = contentSize()
        growsUp = true
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin: NSPoint
        if let a = anchor {
            let fieldTop = primaryHeight - a.minY
            origin = NSPoint(x: a.minX, y: fieldTop + 8)
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: a.midX, y: primaryHeight - a.midY)) } ?? NSScreen.main
            if let vis = screen?.visibleFrame {
                if origin.y + size.height > vis.maxY { origin.y = primaryHeight - a.maxY - size.height - 8; growsUp = false }
                origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
            }
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x - size.width / 2, y: m.y + 16)
            growsUp = true
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        Log.info("panel shown at \(panel.frame)")
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.onKey?(event) == true ? nil : event
            }
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
