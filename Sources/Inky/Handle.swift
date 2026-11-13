import AppKit
import InkyCore
import SwiftUI

/// Grammarly-style handle on the left edge of the focused text field: a thin pill that
/// grows into a round button on hover. Shows how many live issues there are. Click opens
/// the full Inky panel (same as ⌃⌥I).
@MainActor
final class HandleModel: ObservableObject {
    @Published var count = 0
    @Published var worst: EditCategory?
    @Published var checking = false
    /// Live checking is on for this field (the pill turns ink-colored as a privacy cue).
    @Published var liveOn = false
    /// Briefly true after the last suggestion is fixed: the handle draws a check.
    @Published var done = false

    func flashDone() {
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.done = false }
    }
}

@MainActor
final class Handle {
    let model = HandleModel()
    private let panel: NSPanel
    private var lastFrame: CGRect?
    var onClick: () -> Void = {}
    /// Room for the ripple around the 20 pt drop while checking.
    static let size: CGFloat = 32

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.size, height: Self.size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: HandleView(model: model) { [weak self] in self?.onClick() })
        host.sizingOptions = []
        panel.contentView = host
    }

    /// `field` in AX coordinates.
    func show(for field: CGRect) {
        guard field != lastFrame || !panel.isVisible else { return }
        lastFrame = field
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Centered on the first line, just left of the field.
        let lineMid = field.minY + min(field.height, 34) / 2
        let origin = NSPoint(x: field.minX - 13 - Self.size / 2, y: primaryHeight - lineMid - Self.size / 2)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.size, height: Self.size)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        lastFrame = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}

/// The ink drop next to the field. Idle: a quiet drop. Checking: it breathes and sends out
/// a ripple. Issues: a colored dot with the count. All fixed: a check, then back to idle.
private struct HandleView: View {
    @ObservedObject var model: HandleModel
    var action: () -> Void
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Look: Equatable { case idle, checking, issues, done }
    private var look: Look {
        if model.done { return .done }
        if model.checking { return .checking }
        return model.count > 0 ? .issues : .idle
    }

    private var fill: AnyShapeStyle {
        switch look {
        case .idle: AnyShapeStyle(Ink.ink.opacity(hover ? 0.18 : 0.1))
        case .checking, .done: AnyShapeStyle(Ink.ink)
        case .issues: AnyShapeStyle(model.worst.map(Ink.color) ?? Ink.ink)
        }
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                if look == .checking && !reduceMotion { Ripple() }
                Circle()
                    .fill(fill)
                    .frame(width: 20, height: 20)
                    .overlay { symbol }
                    .overlay {
                        // Privacy cue: a ring while live checking is sending what you type.
                        if look == .idle && model.liveOn {
                            Circle().strokeBorder(Ink.ink, lineWidth: 1.5)
                        }
                    }
                    .modifier(Breathe(on: look == .checking && !reduceMotion))
            }
            .frame(width: Handle.size, height: Handle.size)
            .scaleEffect(hover ? 1.12 : 1)
            .contentShape(Circle().inset(by: 6))
        }
        .buttonStyle(.plain)
        .help(model.liveOn ? "Inky · live checking on · ⌃⌥I" : "Inky · ⌃⌥I")
        .onHover { hover = $0 }
        .animation(Ink.pop, value: hover)
        .animation(Ink.pop, value: look)
        .animation(Ink.pop, value: model.count)
    }

    @ViewBuilder private var symbol: some View {
        switch look {
        case .idle:
            Brand.mark(12).foregroundStyle(model.liveOn ? AnyShapeStyle(Ink.ink) : AnyShapeStyle(.secondary))
        case .checking:
            Brand.mark(12).foregroundStyle(Ink.paper)
        case .issues:
            Text("\(model.count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Ink.onColor)   // contrast in both modes (the dark-mode inks are light)
                .contentTransition(.numericText(value: Double(model.count)))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(Ink.paper)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        }
    }
}

private struct Breathe: ViewModifier {
    var on: Bool
    @State private var big = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on && big ? 1.1 : 1)
            .onChange(of: on, initial: true) { _, on in
                if on {
                    withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { big = true }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) { big = false }
                }
            }
    }
}

/// A ring that spreads out from the drop and fades, on a loop.
private struct Ripple: View {
    @State private var spread = false
    var body: some View {
        Circle()
            .strokeBorder(Ink.ink, lineWidth: 1.5)
            .frame(width: 20, height: 20)
            .scaleEffect(spread ? 1.55 : 1)
            .opacity(spread ? 0 : 0.6)
            .onAppear {
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.1).repeatForever(autoreverses: false)) { spread = true }
            }
    }
}
