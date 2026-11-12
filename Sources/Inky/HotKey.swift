import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Global shortcut (default ⌃⌥I) via a CGEvent tap, which sees and swallows the keystroke
/// before the frontmost app does. Needs the Accessibility permission. Falls back to a
/// Carbon hotkey if the tap can't be created (e.g. permission not granted yet).
/// Note: ⌃⌥Space is taken by macOS ("Select next input source").
final class HotKey {
    private let keyCode: Int64
    private let required: CGEventFlags
    private let handler: () -> Void
    private var tap: CFMachPort?
    private var carbonRef: EventHotKeyRef?
    nonisolated(unsafe) private static var carbonHandler: (() -> Void)?

    private(set) var mechanism = "none"
    var registered: Bool { mechanism != "none" }

    init(keyCode: Int = kVK_ANSI_I, flags: CGEventFlags = [.maskControl, .maskAlternate], handler: @escaping () -> Void) {
        self.keyCode = Int64(keyCode)
        self.required = flags
        self.handler = handler
        if installTap() { mechanism = "event tap" } else if installCarbon(keyCode: keyCode) { mechanism = "carbon" }
        Log.info("hotkey via \(mechanism)")
    }

    /// Call after Accessibility is granted to upgrade from Carbon to the event tap.
    func retryTapIfNeeded() {
        guard mechanism != "event tap", installTap() else { return }
        if let carbonRef { UnregisterEventHotKey(carbonRef); self.carbonRef = nil }
        mechanism = "event tap"
        Log.info("hotkey upgraded to event tap")
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            let hk = Unmanaged<HotKey>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = hk.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            if type == .keyDown,
               event.getIntegerValueField(.keyboardEventKeycode) == hk.keyCode,
               event.flags.intersection(relevant) == hk.required {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async { hk.handler() }
                }
                return nil // swallow it so the frontmost app doesn't type anything
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        return true
    }

    private func installCarbon(keyCode: Int) -> Bool {
        HotKey.carbonHandler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in HotKey.carbonHandler?(); return noErr }, 1, &spec, nil, nil)
        var mods = 0
        if required.contains(.maskControl) { mods |= controlKey }
        if required.contains(.maskAlternate) { mods |= optionKey }
        if required.contains(.maskCommand) { mods |= cmdKey }
        if required.contains(.maskShift) { mods |= shiftKey }
        return RegisterEventHotKey(UInt32(keyCode), UInt32(mods), EventHotKeyID(signature: 0x494E_4B59, id: 1),
                                   GetApplicationEventTarget(), 0, &carbonRef) == noErr
    }
}
