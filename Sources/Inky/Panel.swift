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
    /// ⌘E: every note at once instead of one at a time.
    @Published var showExplanations = false
    /// Which note is shown when they're shown one at a time (← →).
    @Published var focused = 0
    @Published var language: ExplanationLanguage = .spanish
    @Published var original = ""
    @Published var edits: [PlannedEdit] = []   // relative to `original`
    /// How the original text sounds, from the model.
    @Published var detectedTone: String?
    /// Edit (by range location) under the mouse, in the panel or over the field.
    @Published var hovered: Int?
    @Published var showCustom = false
    @Published var customInstruction = ""
    /// Drives the grow-in / shrink-out of the whole panel.
    @Published var shown = false
    /// The panel sits above the field and grows up from it (from the handle's corner).
    @Published var growsUp = true
    /// Apply was pressed: the highlights soak in and the button turns into a check,
    /// a beat before the panel closes and Inky types the changes.
    @Published var applying = false

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

/// Inky's visual language: black ink on paper for the UI (it follows light/dark mode),
/// and an ink color per kind of suggestion, the only color on screen.
enum Ink {
    /// Text-colored ink: black in light mode, paper in dark mode.
    static let ink = Color.primary
    /// What goes on top of `ink` (button labels, the mark).
    static let paper = Color(nsColor: .windowBackgroundColor)

    private static func dynamic(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    private static let red = dynamic((0.84, 0.27, 0.18), (0.94, 0.42, 0.32))
    private static let blue = dynamic((0.18, 0.39, 0.88), (0.36, 0.55, 1.0))
    private static let green = dynamic((0.17, 0.54, 0.37), (0.25, 0.70, 0.49))
    private static let violet = dynamic((0.46, 0.32, 0.79), (0.61, 0.49, 0.94))

    static func nsColor(_ c: EditCategory) -> NSColor {
        switch c {
        case .correctness: red
        case .clarity: blue
        case .engagement: green
        case .tone: violet
        }
    }

    static func color(_ c: EditCategory) -> Color { Color(nsColor: nsColor(c)) }

    /// Text on a category-colored fill: white on the light-mode inks, near-black on the
    /// lighter dark-mode inks.
    static let onColor = Color(nsColor: dynamic((1, 1, 1), (0.08, 0.08, 0.08)))

    /// Springs used everywhere, matching the motion prototype.
    static let pop = Animation.spring(duration: 0.32, bounce: 0.25)
    static let settle = Animation.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5)
    /// Opening and closing the panel: slower and with less bounce than small controls.
    static let open = Animation.spring(duration: 0.5, bounce: 0.14)
    static let close = Animation.timingCurve(0.4, 0, 0.6, 1, duration: 0.26)
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    @FocusState private var customFocused: Bool
    @Namespace private var pillSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
        .scaleEffect(model.shown || reduceMotion ? 1 : 0.85, anchor: model.growsUp ? .bottomLeading : .topLeading)
        .opacity(model.shown ? 1 : 0)
        .animation(.smooth(duration: 0.22), value: model.state)
        .animation(Ink.settle, value: model.applying)
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
            Brand.mark(13)
                .foregroundStyle(Ink.paper)
                .frame(width: 20, height: 20)
                .background(Ink.ink, in: RoundedRectangle(cornerRadius: 6))
            Spacer(minLength: 8)
            modePicker
        }
    }

    private var subtitle: String {
        let where_ = model.appName.isEmpty ? "" : " · \(model.appName)"
        switch model.state {
        case .loading: return model.t("Revisando…", "Checking…") + where_
        case .result:
            if model.mode.isWholeText { return model.title(model.mode) + where_ }
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
        .animation(Ink.pop, value: model.mode)
    }

    private func pill(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { pillLabel(title, on: on, chevron: false) }
            .buttonStyle(.plain)
            .help(model.t("Tab cambia de modo", "Tab switches mode"))
    }

    private func pillLabel(_ title: String, on: Bool, chevron: Bool) -> some View {
        HStack(spacing: 3) {
            Text(title).lineLimit(1).fixedSize()
            if chevron { Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
        }
        .font(.caption.weight(on ? .semibold : .regular))
        .foregroundStyle(on ? .primary : .secondary)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background {
            if on {
                // One pill that slides between modes.
                RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.9))
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                    .matchedGeometryEffect(id: "pill", in: pillSpace)
            }
        }
        .contentShape(Rectangle())
    }

    private var customField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
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
            // The text being checked, with a line of ink sweeping across it.
            Text(model.original)
                .font(.system(size: 16, design: .serif))
                .lineSpacing(3)
                .foregroundStyle(.tertiary)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(Shimmer(on: !reduceMotion))
                .transition(.opacity)
        case .noChanges:
            VStack(alignment: .leading, spacing: 6) {
                Label(model.t("Se ve bien", "Looks good"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Ink.ink)
                    .symbolEffect(.bounce, options: .nonRepeating, value: model.state)
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
                        .font(.system(size: 16, design: .serif))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 200)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    toneLine
                    Spacer(minLength: 0)
                    if !model.showExplanations { stepper }
                }

                if !model.showExplanations {
                    focusNote.opacity(model.applying ? 0.35 : 1)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(sortedEdits.enumerated()), id: \.element.range.location) { i, e in
                            note(e).modifier(Rise(delay: 0.12 + Double(i) * 0.08, on: !reduceMotion))
                                .opacity(model.applying ? 0.35 : 1)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .transition(.opacity)
        }
    }

    /// The note for the change under the mouse (here or in the field), else the focused one.
    private var focusIndex: Int {
        let list = sortedEdits
        if let h = model.hovered, let i = list.firstIndex(where: { $0.range.location == h }) { return i }
        return min(max(model.focused, 0), max(list.count - 1, 0))
    }

    @ViewBuilder private var focusNote: some View {
        let list = sortedEdits
        if !list.isEmpty {
            let e = list[focusIndex]
            note(e)
                .id(e.range.location)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)), removal: .opacity))
                .modifier(Rise(delay: 0.15, on: !reduceMotion))
                .animation(Ink.settle, value: focusIndex)
        }
    }

    /// "‹ 2 de 3 ›" to walk through the notes one by one.
    @ViewBuilder private var stepper: some View {
        let n = sortedEdits.count
        if n > 1 {
            HStack(spacing: 2) {
                stepButton("chevron.left") { model.focused = (focusIndex - 1 + n) % n; model.hovered = nil }
                Text(model.t("\(focusIndex + 1) de \(n)", "\(focusIndex + 1) of \(n)"))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(focusIndex)))
                stepButton("chevron.right") { model.focused = (focusIndex + 1) % n; model.hovered = nil }
            }
            .help(model.t("← → para ver cada cambio · ⌘E todos", "← → to step through · ⌘E all"))
            .animation(Ink.settle, value: focusIndex)
        }
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold)).frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary)
    }

    @ViewBuilder private var toneLine: some View {
        if let tone = model.detectedTone, !tone.isEmpty, !model.mode.isWholeText {
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
                    if !model.mode.isWholeText {
                        (Text(removed(e)).strikethrough().foregroundStyle(.secondary)
                         + Text("  →  ").foregroundStyle(.tertiary)
                         + Text(e.replacement.isEmpty ? "∅" : e.replacement).bold())
                            .font(.system(size: 13))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if !model.mode.isWholeText {
                        Text(model.label(e.category).uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(color)
                    }
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

    /// Status on the left, actions on the right. Shortcuts live in tooltips and menus.
    private var footer: some View {
        HStack(spacing: 6) {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .contentTransition(.opacity)
            Spacer()
            Button("Esc") { model.onCancel() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                .help(model.t("Cerrar sin cambios", "Close without changes"))
            if case .result = model.state {
                Button { model.onApply() } label: {
                    HStack(spacing: 4) {
                        // Not "done" yet: the check comes from the handle once the text is really in.
                        Text(model.applying ? model.t("Aplicando…", "Applying…") : model.t("Aplicar ↩", "Apply ↩"))
                            .contentTransition(.opacity)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Ink.paper)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Ink.ink, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(PressStyle())
                .help(model.t("Enter aplica · ⌘E oculta las notas", "Enter applies · ⌘E hides notes"))
            }
        }
        .animation(Ink.pop, value: model.applying)
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
            if !model.mode.isWholeText && !model.applying {
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

/// A soft band of ink that sweeps across the content while Inky is checking.
private struct Shimmer: ViewModifier {
    var on: Bool
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content.overlay {
            if on {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, Ink.ink.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: g.size.width * 0.45)
                        .offset(x: -g.size.width * 0.45 + phase * g.size.width * 1.45)
                }
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
                }
            }
        }
    }
}

/// Fades and lifts a row into place after `delay`, so notes arrive one by one.
private struct Rise: ViewModifier {
    var delay: Double
    var on: Bool
    @State private var up = false
    func body(content: Content) -> some View {
        content
            .opacity(up || !on ? 1 : 0)
            .offset(y: up || !on ? 0 : 6)
            .onAppear { withAnimation(Ink.settle.delay(delay)) { up = true } }
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
    /// Bumped on every show/hide so a late hide doesn't close a panel shown again.
    private var generation = 0

    var onKey: ((NSEvent) -> Bool)?
    /// A click outside the panel (in another app or another part of the screen).
    var onOutsideClick: (() -> Void)?
    private var clickMonitor: Any?
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
        generation += 1
        let wasVisible = panel.isVisible
        model.growsUp = growsUp
        if !wasVisible { model.shown = false }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        if !model.shown { DispatchQueue.main.async { [model] in withAnimation(Ink.open) { model.shown = true } } }
        Log.info("panel shown at \(panel.frame)")
        if clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.panel.isVisible, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                    self.onOutsideClick?()
                }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.panel.isKeyWindow else { return event }
                return self.onKey?(event) == true ? nil : event
            }
        }
    }

    func hide(animated: Bool = true) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard panel.isVisible else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            generation += 1
            model.shown = false
            panel.orderOut(nil)
            return
        }
        // Shrink back toward the field, then take the window away (unless shown again meanwhile).
        generation += 1
        let g = generation
        withAnimation(Ink.close) { model.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.27) { [weak self] in
            guard let self, self.generation == g else { return }
            self.panel.orderOut(nil)
        }
    }
}
