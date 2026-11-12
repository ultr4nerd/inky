import AppKit
import InkyCore
import SwiftUI

/// Small card shown above an underlined word: category, the change in context, the
/// explanation, and a button to apply just this fix.
@MainActor
final class CardModel: ObservableObject {
    @Published var edit: PlannedEdit?
    @Published var context = ""          // the field text around the edit
    @Published var contextRange = NSRange()  // edit range inside `context`
    @Published var language: ExplanationLanguage = .spanish
    /// Drives the pop-in; reset on every show.
    @Published var shown = false
    /// The card sits below the word (no room above), so it grows from its top edge.
    @Published var below = false
    var onApply: (PlannedEdit) -> Void = { _ in }
    var onIgnore: (PlannedEdit) -> Void = { _ in }
    func t(_ es: String, _ en: String) -> String { language == .spanish ? es : en }
}

@MainActor
final class SuggestionCard {
    let model = CardModel()
    private let panel: NSPanel
    private let measurer: NSHostingController<CardView>
    private(set) var shownID: Int?

    var frame: NSRect { panel.frame }
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: CardView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        measurer = NSHostingController(rootView: CardView(model: model))
    }

    /// `wordRect` in AX coordinates.
    func show(_ edit: PlannedEdit, fieldText: String, wordRect: CGRect, language: ExplanationLanguage) {
        let ns = fieldText as NSString
        // ~40 characters of context on each side, cut at word boundaries.
        let start = max(0, edit.range.location - 40), end = min(ns.length, NSMaxRange(edit.range) + 40)
        var ctx = ns.substring(with: NSRange(location: start, length: end - start))
        var offset = edit.range.location - start
        if start > 0, let sp = ctx.firstIndex(of: " "), ctx.distance(from: ctx.startIndex, to: sp) < offset {
            let cut = ctx.distance(from: ctx.startIndex, to: sp) + 1
            ctx = "…" + String(ctx.dropFirst(cut)); offset = offset - cut + 1
        }
        if end < ns.length, let sp = ctx.lastIndex(of: " "), ctx.distance(from: ctx.startIndex, to: sp) > offset + edit.range.length {
            ctx = String(ctx[..<sp]) + "…"
        }
        model.language = language
        model.context = ctx
        model.contextRange = NSRange(location: offset, length: edit.range.length)
        model.edit = edit
        shownID = edit.range.location

        let size = measurer.sizeThatFits(in: NSSize(width: 300, height: 600))
        let h = max(ceil(size.height), 60)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var origin = NSPoint(x: wordRect.minX - 14, y: primaryHeight - wordRect.minY + 6)
        if let vis = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - 308)
            model.below = origin.y + h > vis.maxY
            if model.below { origin.y = primaryHeight - wordRect.maxY - h - 6 }
        }
        model.shown = false
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 300, height: h)), display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.async { [model] in withAnimation(Ink.pop) { model.shown = true } }
    }

    func hide() {
        shownID = nil
        if panel.isVisible { panel.orderOut(nil) }
        model.edit = nil
    }
}

private struct CardView: View {
    @ObservedObject var model: CardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let e = model.edit {
            let color = Ink.color(e.category)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(label(e.category).uppercased())
                        .font(.system(size: 10, weight: .semibold)).tracking(0.5)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Brand.mark(11).foregroundStyle(.tertiary)
                }
                DiffLine(old: removed(e), new: e.replacement, animate: !reduceMotion)
                    .id(e.range.location)
                if !e.explanation.isEmpty {
                    Text(e.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { model.onApply(e) } label: {
                        Text(e.replacement.isEmpty ? model.t("Quitar", "Remove") : e.replacement)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.paper)
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(Ink.ink, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(PressStyle())
                    Button(model.t("Ignorar", "Dismiss")) { model.onIgnore(e) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .background { background }
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.08)) }
            .scaleEffect(model.shown || reduceMotion ? 1 : 0.94, anchor: model.below ? .topLeading : .bottomLeading)
            .opacity(model.shown ? 1 : 0)
        }
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 14))
        } else {
            RoundedRectangle(cornerRadius: 14).fill(.regularMaterial)
        }
    }

    private func label(_ c: EditCategory) -> String {
        switch c {
        case .correctness: model.t("Corrección", "Correctness")
        case .clarity: model.t("Claridad", "Clarity")
        case .engagement: model.t("Interés", "Engagement")
        case .tone: model.t("Tono", "Tone")
        }
    }

    private func removed(_ e: PlannedEdit) -> String {
        let ns = model.context as NSString
        let r = model.contextRange
        guard NSMaxRange(r) <= ns.length else { return "" }
        return ns.substring(with: r)
    }
}

/// "~~sent~~ → send": the old word gets struck through, then the new one is written in.
private struct DiffLine: View {
    var old: String
    var new: String
    var animate: Bool
    @State private var struck = false
    @State private var written = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(old)
                .foregroundStyle(.secondary)
                .overlay {
                    Rectangle().frame(height: 1.5).offset(y: 1)
                        .foregroundStyle(.secondary)
                        .scaleEffect(x: struck ? 1 : 0, anchor: .leading)
                }
            Text("→").foregroundStyle(.tertiary)
            Text(new.isEmpty ? "∅" : new)
                .fontWeight(.semibold)
                .mask(alignment: .leading) {
                    Rectangle().scaleEffect(x: written ? 1 : 0, anchor: .leading)
                }
        }
        .font(.system(size: 16, design: .serif))
        .lineLimit(2)
        .onAppear {
            guard animate else { struck = true; written = true; return }
            withAnimation(Ink.settle.delay(0.1)) { struck = true }
            withAnimation(Ink.settle.delay(0.3)) { written = true }
        }
    }
}

/// Buttons squish a little when pressed.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(Ink.pop, value: configuration.isPressed)
    }
}
