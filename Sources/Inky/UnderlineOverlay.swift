import AppKit
import InkyCore
import QuartzCore

/// Draws wavy underlines directly over the words in the other app's text field.
/// New underlines are drawn left to right, one after another, like a pen stroke; ones that
/// were already on screen stay put. The window ignores the mouse; hovering is tracked with a
/// global monitor so clicks still reach the app underneath.
@MainActor
final class UnderlineOverlay {
    struct Mark { var id: Int; var key: String; var rect: CGRect; var color: NSColor }   // rect in Cocoa coordinates

    private var window: NSWindow?
    private var view: OverlayView?
    private var monitor: Any?
    /// Keys of the marks on screen (or just hidden), so a re-render doesn't redraw them.
    private var seen: Set<String> = []
    var onHover: ((Int?) -> Void)?
    var hoveredID: Int? { view?.hovered }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func show(_ marks: [(id: Int, axRect: CGRect, color: NSColor)]) {
        show(marks.map { (id: $0.id, key: "\($0.id)", axRect: $0.axRect, color: $0.color) })
    }

    /// `axRect`s are in AX coordinates (top-left origin). `key` identifies the suggestion
    /// across re-renders (e.g. the word and its replacement).
    func show(_ marks: [(id: Int, key: String, axRect: CGRect, color: NSColor)]) {
        hide()
        guard !marks.isEmpty, let primary = NSScreen.screens.first else { seen = []; return }
        let cocoa = marks.map { m in
            Mark(id: m.id, key: m.key, rect: CGRect(x: m.axRect.minX, y: primary.frame.height - m.axRect.maxY,
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
        let local = cocoa.map { Mark(id: $0.id, key: $0.key, rect: $0.rect.offsetBy(dx: -bounds.minX, dy: -bounds.minY), color: $0.color) }
        let fresh = Set(local.map(\.key)).subtracting(seen)
        v.build(local, animate: Self.reduceMotion ? [] : fresh)
        seen = Set(local.map(\.key))
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
        view?.setHovered(id)
    }

    /// `forget`: the next marks are all new (a new message or a new check), so draw them in.
    func hide(forget: Bool = false) {
        window?.orderOut(nil)
        window = nil
        view = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if forget { seen = [] }
    }

    private func mouseMoved(_ p: NSPoint) {
        guard let w = window, let v = view else { return }
        let local = NSPoint(x: p.x - w.frame.minX, y: p.y - w.frame.minY)
        let hit = v.marks.first { $0.rect.insetBy(dx: -2, dy: -4).contains(local) }?.id
        highlight(hit)
        onHover?(hit)
    }

    // MARK: Splash

    private static var splashes: [NSWindow] = []

    /// A small ink ring that spreads from under a word when a fix is applied.
    static func splash(at axRect: CGRect, color: NSColor) {
        guard !reduceMotion, let primary = NSScreen.screens.first else { return }
        let size: CGFloat = 44
        let center = NSPoint(x: axRect.midX, y: primary.frame.height - axRect.maxY + 1)
        let w = NSWindow(contentRect: NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size),
                         styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.wantsLayer = true
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: size / 2 - 4, y: size / 2 - 4, width: 8, height: 8), transform: nil)
        ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        ring.position = CGPoint(x: size / 2, y: size / 2)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        v.layer?.addSublayer(ring)
        w.contentView = v
        w.orderFrontRegardless()
        splashes.append(w)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3; grow.toValue = 3.0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.6, 0.3, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: "splash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
            w.orderOut(nil)
            splashes.removeAll { $0 === w }
        }
    }
}

final class OverlayView: NSView {
    private(set) var marks: [UnderlineOverlay.Mark] = []
    private(set) var hovered: Int?
    private var waves: [Int: CAShapeLayer] = [:]
    private var fills: [Int: CAShapeLayer] = [:]

    override var isFlipped: Bool { false }

    func build(_ marks: [UnderlineOverlay.Mark], animate fresh: Set<String>) {
        self.marks = marks
        wantsLayer = true
        guard let root = layer else { return }
        let now = CACurrentMediaTime()
        var delay = 0.0
        for m in marks.sorted(by: { ($0.rect.maxY, -$0.rect.minX) > ($1.rect.maxY, -$1.rect.minX) }) {
            let fill = CAShapeLayer()
            fill.path = CGPath(roundedRect: m.rect.insetBy(dx: -1, dy: 0), cornerWidth: 3, cornerHeight: 3, transform: nil)
            fill.fillColor = m.color.withAlphaComponent(0.16).cgColor
            fill.opacity = 0
            root.addSublayer(fill)
            fills[m.id] = fill

            let wave = CAShapeLayer()
            wave.path = Self.wave(under: m.rect)
            wave.fillColor = nil
            wave.strokeColor = m.color.cgColor
            wave.lineWidth = 1.6
            wave.lineCap = .round
            root.addSublayer(wave)
            waves[m.id] = wave

            if fresh.contains(m.key) {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0; draw.toValue = 1
                draw.duration = 0.5
                draw.beginTime = now + delay
                draw.fillMode = .backwards
                draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                wave.add(draw, forKey: "draw")
                delay += 0.14
            }
        }
    }

    func setHovered(_ id: Int?) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        if let old = hovered { fills[old]?.opacity = 0; waves[old]?.lineWidth = 1.6 }
        hovered = id
        if let id { fills[id]?.opacity = 1; waves[id]?.lineWidth = 2.2 }
        CATransaction.commit()
    }

    /// Gentle wave under the word, like a margin mark in ink.
    private static func wave(under r: CGRect) -> CGPath {
        let path = CGMutablePath()
        let y = r.minY + 1
        path.move(to: CGPoint(x: r.minX, y: y))
        var x = r.minX
        var up = true
        while x < r.maxX {
            let nx = min(x + 3, r.maxX)
            let dy: CGFloat = up ? 1.6 : -1.6
            path.addCurve(to: CGPoint(x: nx, y: y), control1: CGPoint(x: x + 1, y: y + dy), control2: CGPoint(x: nx - 1, y: y + dy))
            x = nx
            up.toggle()
        }
        return path
    }
}
