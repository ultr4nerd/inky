import AppKit
import ApplicationServices
import Carbon.HIToolbox
import InkyCore

/// What Inky read from the focused field. Offsets are UTF-16, like Accessibility.
struct FieldSnapshot {
    var app: NSRunningApplication
    var element: AXUIElement?
    /// Full field value (AX) or the copied text (clipboard).
    var fieldText: String
    /// The part being corrected: the selection, or the whole field.
    var target: NSRange
    /// Mentions etc., relative to `targetText`.
    var protected: [NSRange]
    var viaClipboard: Bool
    /// Field frame in AX (top-left origin) coordinates, for anchoring the panel.
    var anchor: CGRect?

    var targetText: String { (fieldText as NSString).substring(with: target) }
}

enum TextAccessError: LocalizedError {
    case noApp, secureField, noText
    var errorDescription: String? {
        switch self {
        case .noApp: "No active app."
        case .secureField: "Inky never reads password fields."
        case .noText: "Couldn't find text to check. Click into a text field first."
        }
    }
}

@MainActor
enum TextAccess {
    // MARK: Read

    static func read() throws -> FieldSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else { throw TextAccessError.noApp }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium apps (Slack) only expose their text tree when asked.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        var focused = attr(appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        if focused == nil {
            Thread.sleep(forTimeInterval: 0.3) // tree may be building right after enabling it
            focused = attr(appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
        }
        if let el = focused {
            let role = attr(el, kAXRoleAttribute) as? String
            let subrole = attr(el, kAXSubroleAttribute) as? String
            if role == "AXSecureTextField" || subrole == "AXSecureTextField" { throw TextAccessError.secureField }
            if let value = attr(el, kAXValueAttribute) as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let length = (value as NSString).length
                var target = NSRange(location: 0, length: length)
                if let sel = selectedRange(el), sel.length > 0, NSMaxRange(sel) <= length { target = sel }
                let mentions = mentionRanges(in: el, value: value)
                    .compactMap { r -> NSRange? in
                        let i = NSIntersectionRange(r, target)
                        return i.length == r.length ? NSRange(location: r.location - target.location, length: r.length) : nil
                    }
                return FieldSnapshot(app: app, element: el, fieldText: value, target: target,
                                     protected: mentions, viaClipboard: false, anchor: frame(el))
            }
        }
        return try readViaClipboard(app: app, element: focused)
    }

    private static func readViaClipboard(app: NSRunningApplication, element: AXUIElement?) throws -> FieldSnapshot {
        let pb = NSPasteboard.general
        let saved = savePasteboard()
        let before = pb.changeCount
        pressKey(kVK_ANSI_C, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.15)
        if pb.changeCount == before { // nothing selected: select all and copy
            pressKey(kVK_ANSI_A, flags: .maskCommand)
            Thread.sleep(forTimeInterval: 0.05)
            pressKey(kVK_ANSI_C, flags: .maskCommand)
            Thread.sleep(forTimeInterval: 0.15)
        }
        let text = pb.changeCount != before ? pb.string(forType: .string) : nil
        restorePasteboard(saved)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextAccessError.noText }
        return FieldSnapshot(app: app, element: nil, fieldText: text,
                             target: NSRange(location: 0, length: (text as NSString).length),
                             protected: [], viaClipboard: true, anchor: element.flatMap(frame))
    }

    // MARK: Write

    /// Applies edits (relative to the target text). Returns false if the field doesn't
    /// end up with the expected text.
    static func apply(_ edits: [PlannedEdit], to snap: FieldSnapshot, result: String) async -> Bool {
        snap.app.activate()
        try? await Task.sleep(for: .milliseconds(150))

        if snap.viaClipboard {
            let saved = savePasteboard()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
            pressKey(kVK_ANSI_V, flags: .maskCommand)
            try? await Task.sleep(for: .milliseconds(400))
            restorePasteboard(saved)
            return true
        }
        guard let el = snap.element else { return false }
        // Slack ignores AXSelectedText and AXReplaceRangeWithText, so: select the range, then type.
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            var r = CFRange(location: snap.target.location + edit.range.location, length: edit.range.length)
            AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, AXValueCreate(.cfRange, &r)!)
            try? await Task.sleep(for: .milliseconds(30))
            if edit.replacement.isEmpty { pressKey(kVK_Delete) } else { type(edit.replacement) }
            try? await Task.sleep(for: .milliseconds(30))
        }
        let expected = normalized((snap.fieldText as NSString).replacingCharacters(in: snap.target, with: result))
        // Slack updates its AX value a little after the keystrokes, and longer texts take longer.
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            if let value = attr(el, kAXValueAttribute) as? String, normalized(value) == expected { return true }
        }
        let got = (attr(el, kAXValueAttribute) as? String).map(normalized) ?? ""
        Log.info("verify mismatch: expected \(expected.count) chars, got \(got.count)")
        return false
    }

    /// Slack (and macOS) may swap straight quotes for curly ones, use non-breaking spaces,
    /// or keep a trailing newline. None of that means the fix went wrong.
    static func normalized(_ s: String) -> String {
        var t = s
        for (a, b) in [("\u{2019}", "'"), ("\u{2018}", "'"), ("\u{201C}", "\""), ("\u{201D}", "\""),
                       ("\u{00A0}", " "), ("\u{202F}", " ")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    static func selectedRange(_ e: AXUIElement) -> NSRange? {
        guard let v = attr(e, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        AXValueGetValue(v as! AXValue, .cfRange, &r)
        return NSRange(location: r.location, length: r.length)
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
        var point = CGPoint(), size = CGSize()
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// Slack exposes each mention/channel as its own AXStaticText ("@Ana", "#general").
    static func mentionRanges(in el: AXUIElement, value: String) -> [NSRange] {
        var texts: [String] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 6 else { return }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if attr(c, kAXRoleAttribute) as? String == "AXStaticText", let t = attr(c, kAXValueAttribute) as? String {
                    texts.append(t)
                } else { walk(c, depth: depth + 1) }
            }
        }
        walk(el, depth: 0)
        let ns = value as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        for t in texts {
            let r = ns.range(of: t, range: NSRange(location: cursor, length: ns.length - cursor))
            guard r.location != NSNotFound else { continue }
            cursor = NSMaxRange(r)
            if let first = t.first, "@#".contains(first), !t.contains(" ") { ranges.append(r) }
        }
        return ranges
    }

    /// Types text as keyboard input. Newlines become Shift+Return so chat apps don't send the message.
    static func type(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let units = Array(line.utf16)
            var start = 0
            while start < units.count {
                let chunk = Array(units[start..<min(start + 16, units.count)])
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
                down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                start += 16
            }
            if i < lines.count - 1 { pressKey(kVK_Return, flags: .maskShift) }
        }
    }

    static func pressKey(_ key: Int, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: down)!
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    private static func savePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    private static func restorePasteboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(saved.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict { item.setData(d, forType: t) }
            return item
        })
    }
}

// MARK: - Word positions (for underlines)

extension TextAccess {
    /// Screen rects (AX coordinates) for each planned edit, keyed by edit range location.
    /// Native apps answer AXBoundsForRange. Chromium/Electron (Slack) returns the whole field
    /// there, so walk the text markers of each AXStaticText run instead (no selection change,
    /// works in the background, ~10 ms).
    static func rects(for edits: [PlannedEdit], in snap: FieldSnapshot) -> [Int: CGRect] {
        guard let el = snap.element, !snap.viaClipboard else { return [:] }
        var out: [Int: CGRect] = [:]
        var pending: [PlannedEdit] = []
        for e in edits {
            let abs = NSRange(location: snap.target.location + e.range.location, length: max(e.range.length, 1))
            if let r = boundsForRange(el, abs), r.height < 60 { out[e.range.location] = r } else { pending.append(e) }
        }
        guard !pending.isEmpty else { return out }

        // Text runs in order, with their offset in the field value.
        let ns = snap.fieldText as NSString
        var runs: [(el: AXUIElement, range: NSRange)] = []
        var cursor = 0
        func walk(_ e: AXUIElement, _ depth: Int) {
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                if attr(c, kAXRoleAttribute) as? String == "AXStaticText", let t = attr(c, kAXValueAttribute) as? String, !t.isEmpty {
                    let r = ns.range(of: t, range: NSRange(location: cursor, length: ns.length - cursor))
                    if r.location != NSNotFound { runs.append((c, r)); cursor = NSMaxRange(r) }
                } else if depth < 6 { walk(c, depth + 1) }
            }
        }
        walk(el, 0)

        func param(_ a: String, _ p: AnyObject) -> AnyObject? {
            var o: AnyObject?
            return AXUIElementCopyParameterizedAttributeValue(el, a as CFString, p, &o) == .success ? o : nil
        }
        var markerCache: [Int: [AnyObject]] = [:]
        func markers(_ i: Int) -> [AnyObject]? {
            if let m = markerCache[i] { return m }
            guard let kr = param("AXTextMarkerRangeForUIElement", runs[i].el), CFGetTypeID(kr) == AXTextMarkerRangeGetTypeID() else { return nil }
            var ms: [AnyObject] = [AXTextMarkerRangeCopyStartMarker(kr as! AXTextMarkerRange)]
            for _ in 0..<runs[i].range.length {
                guard let n = param("AXNextTextMarkerForTextMarker", ms.last!) else { break }
                ms.append(n)
            }
            markerCache[i] = ms
            return ms
        }

        for e in pending {
            let abs = NSRange(location: snap.target.location + e.range.location, length: max(e.range.length, 1))
            var union: CGRect?
            for (i, run) in runs.enumerated() {
                let overlap = NSIntersectionRange(run.range, abs)
                guard overlap.length > 0, let ms = markers(i) else { continue }
                let a = overlap.location - run.range.location, b = NSMaxRange(overlap) - run.range.location
                guard b < ms.count,
                      let r = param("AXTextMarkerRangeForUnorderedTextMarkers", [ms[a], ms[b]] as CFArray),
                      let rect = cgRect(param("AXBoundsForTextMarkerRange", r)), rect.width > 0 else { continue }
                union = union.map { $0.union(rect) } ?? rect
            }
            if let union { out[e.range.location] = union }
        }
        return out
    }

    struct FocusedField {
        var app: NSRunningApplication
        var element: AXUIElement
        var frame: CGRect
        var value: String
    }

    /// The focused editable text field of the frontmost app, if any (handle + live checking).
    static func focusedField() -> FocusedField? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let f = attr(appEl, kAXFocusedUIElementAttribute) else { return nil }
        let el = f as! AXUIElement
        let role = attr(el, kAXRoleAttribute) as? String
        let subrole = attr(el, kAXSubroleAttribute) as? String
        guard role == "AXTextArea" || (role == "AXTextField" && subrole != "AXSecureTextField" && subrole != "AXSearchField")
        else { return nil }
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue, let fr = frame(el), fr.width > 120, fr.height > 14 else { return nil }
        return FocusedField(app: app, element: el, frame: fr, value: attr(el, kAXValueAttribute) as? String ?? "")
    }

    /// Snapshot of a whole field (no selection), for live checking.
    static func snapshot(of field: FocusedField) -> FieldSnapshot {
        let length = (field.value as NSString).length
        return FieldSnapshot(app: field.app, element: field.element, fieldText: field.value,
                             target: NSRange(location: 0, length: length),
                             protected: mentionRanges(in: field.element, value: field.value),
                             viaClipboard: false, anchor: field.frame)
    }

    private static func boundsForRange(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        var r = CFRange(location: range.location, length: range.length)
        var b: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         AXValueCreate(.cfRange, &r)!, &b) == .success,
              let rect = cgRect(b), rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func cgRect(_ v: AnyObject?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var rect = CGRect()
        return AXValueGetValue(v as! AXValue, .cgRect, &rect) ? rect : nil
    }
}
