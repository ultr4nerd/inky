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
}

@MainActor
final class Handle {
    let model = HandleModel()
    private let panel: NSPanel
    private var lastFrame: CGRect?
    var onClick: () -> Void = {}

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 26, height: 26),
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
        let origin = NSPoint(x: field.minX - 26, y: primaryHeight - lineMid - 13)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: 26, height: 26)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        lastFrame = nil
        if panel.isVisible { panel.orderOut(nil) }
    }
}

private struct HandleView: View {
    @ObservedObject var model: HandleModel
    var action: () -> Void
    @State private var hover = false

    private var tint: Color { model.worst.map(Ink.color) ?? Ink.accent }

    var body: some View {
        Button(action: action) {
            ZStack {
                if hover || model.count > 0 {
                    Circle()
                        .fill(hover ? tint : tint.opacity(0.9))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if model.count > 0 && !hover {
                                Text("\(model.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            } else {
                                Image(systemName: "pencil.tip").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Capsule()
                        .fill(.secondary.opacity(model.checking ? 0.9 : 0.55))
                        .frame(width: 4, height: 18)
                        .transition(.opacity)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Inky · ⌃⌥I")
        .onHover { hover = $0 }
        .animation(.spring(duration: 0.2), value: hover)
        .animation(.spring(duration: 0.2), value: model.count)
    }
}
