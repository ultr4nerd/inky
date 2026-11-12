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
            if origin.y + h > vis.maxY { origin.y = primaryHeight - wordRect.maxY - h - 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 300, height: h)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        shownID = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private struct CardView: View {
    @ObservedObject var model: CardModel

    var body: some View {
        if let e = model.edit {
            let color = Ink.color(e.category)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Circle().fill(color).frame(width: 7, height: 7)
                    Text(label(e.category)).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    Spacer()
                    Image(systemName: "pencil.tip").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                }
                Text(contextDiff(e, color: color)).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                if !e.explanation.isEmpty {
                    Text(e.explanation).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button { model.onApply(e) } label: {
                        Text(e.replacement.isEmpty ? model.t("Quitar", "Remove") : e.replacement)
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(color, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    Button(model.t("Ignorar", "Dismiss")) { model.onIgnore(e) }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
            .background { background }
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)) }
        }
    }

    @ViewBuilder private var background: some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.regularMaterial)
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

    /// "…when you ~~will~~ have time…" with the replacement inserted in color.
    private func contextDiff(_ e: PlannedEdit, color: Color) -> AttributedString {
        let ns = model.context as NSString
        let r = model.contextRange
        guard NSMaxRange(r) <= ns.length else { return AttributedString(model.context) }
        var out = AttributedString(ns.substring(to: r.location))
        out.foregroundColor = .secondary
        var del = AttributedString(ns.substring(with: r))
        del.strikethroughStyle = Text.LineStyle(pattern: .solid, color: .red)
        del.foregroundColor = .secondary
        var ins = AttributedString(e.replacement.isEmpty ? "" : " " + e.replacement)
        ins.foregroundColor = color
        ins.font = .system(size: 14, weight: .semibold)
        var tail = AttributedString(ns.substring(from: NSMaxRange(r)))
        tail.foregroundColor = .secondary
        out += del; out += ins; out += tail
        return out
    }
}
