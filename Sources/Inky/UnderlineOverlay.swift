import AppKit
import InkyCore

/// Draws Grammarly-style underlines directly over the words in the other app's text field.
/// The window ignores the mouse; hovering is tracked with a global monitor so clicks still
/// reach the app underneath.
@MainActor
final class UnderlineOverlay {
    struct Mark { var id: Int; var rect: CGRect; var color: NSColor }   // rect in Cocoa coordinates

    private var window: NSWindow?
    private var view: OverlayView?
    private var monitor: Any?
    var onHover: ((Int?) -> Void)?
    var hoveredID: Int? { view?.hovered }

    /// `rects` are in AX coordinates (top-left origin).
    func show(_ marks: [(id: Int, axRect: CGRect, color: NSColor)]) {
        hide()
        guard !marks.isEmpty, let primary = NSScreen.screens.first else { return }
        let cocoa = marks.map { m in
            Mark(id: m.id, rect: CGRect(x: m.axRect.minX, y: primary.frame.height - m.axRect.maxY,
                                        width: m.axRect.width, height: m.axRect.height), color: m.color)
        }
        let bounds = cocoa.map(\.rect).reduce(cocoa[0].rect) { $0.union($1) }.insetBy(dx: -6, dy: -6)

        let w = NSWindow(contentRect: bounds, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .transient, .fullScreenAuxiliary]
        let v = OverlayView(frame: NSRect(origin: .zero, size: bounds.size))
        v.marks = cocoa.map { Mark(id: $0.id, rect: $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), color: $0.color) }
        w.contentView = v
        w.orderFrontRegardless()
        window = w
        view = v

        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(NSEvent.mouseLocation) }
        }
    }

    func highlight(_ id: Int?) {
        guard view?.hovered != id else { return }
        view?.hovered = id
        view?.needsDisplay = true
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
        view = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func mouseMoved(_ p: NSPoint) {
        guard let w = window, let v = view else { return }
        let local = NSPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
        let hit = v.marks.first { $0.rect.insetBy(dx: -2, dy: -4).contains(local) }?.id
        highlight(hit)
        onHover?(hit)
    }
}

final class OverlayView: NSView {
    var marks: [UnderlineOverlay.Mark] = []
    var hovered: Int?

    override func draw(_ dirtyRect: NSRect) {
        for m in marks {
            if m.id == hovered {
                m.color.withAlphaComponent(0.18).setFill()
                NSBezierPath(roundedRect: m.rect.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
            }
            // Gentle wave under the word, like a margin mark in ink.
            let path = NSBezierPath()
            let y = m.rect.minY + 1
            path.move(to: NSPoint(x: m.rect.minX, y: y))
            var x = m.rect.minX
            var up = true
            while x < m.rect.maxX {
                let nx = min(x + 3, m.rect.maxX)
                path.curve(to: NSPoint(x: nx, y: y), controlPoint1: NSPoint(x: x + 1, y: y + (up ? 1.6 : -1.6)),
                           controlPoint2: NSPoint(x: nx - 1, y: y + (up ? 1.6 : -1.6)))
                x = nx
                up.toggle()
            }
            path.lineWidth = m.id == hovered ? 2.2 : 1.6
            path.lineCapStyle = .round
            m.color.setStroke()
            path.stroke()
        }
    }
}
