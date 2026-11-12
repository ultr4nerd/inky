import AppKit
import InkyCore

/// Live checking while you type (Phase 2), Slack only for now:
/// after a short pause, each new or changed sentence goes to the model (one sentence per
/// request, cached), and the results are drawn as underlines on the words. Hovering an
/// underline opens a small card to apply or dismiss that fix.
@MainActor
final class LiveController {
    nonisolated static let enabledKey = "liveEnabled"
    static let apps: Set<String> = ["com.tinyspeck.slackmacgap"]
    static let pause: TimeInterval = 1.2

    let handle = Handle()
    private let overlay = UnderlineOverlay()
    private let card = SuggestionCard()
    private var timer: Timer?

    private var provider: Provider?
    private var providerSignature = ""

    /// True while the full panel is open.
    var suspended = false { didSet { if suspended { clearMarks(); handle.hide() } } }

    private var lastValue: String?
    private var lastChange = Date()
    private var lastFrame: CGRect?
    private var renderedValue: String?
    private var cache: [String: [Edit]] = [:]          // trimmed sentence → edits (relative to sentence)
    private var ignored: Set<String> = []              // "sentence|original"
    private var inFlight = false
    private var current: (snap: FieldSnapshot, edits: [PlannedEdit], rects: [Int: CGRect], sentenceOf: [Int: String])?

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func start() {
        card.model.onApply = { [weak self] in self?.apply($0) }
        card.model.onIgnore = { [weak self] in self?.ignore($0) }
        overlay.onHover = { [weak self] in self?.hovered($0) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func currentProvider() -> Provider {
        let sig = Prefs.providerSignature
        if provider == nil || sig != providerSignature {
            provider = Prefs.makeProvider(purpose: "live")   // its own process, separate from the panel's
            providerSignature = sig
            if let claude = provider as? ClaudeCodeProvider { Task { await claude.warmUp(system: PromptBuilder.system) } }
        }
        return provider!
    }

    // MARK: Loop

    private func tick() {
        guard !suspended, AXIsProcessTrusted(), let field = TextAccess.focusedField() else {
            clearMarks(); handle.hide(); return
        }
        handle.show(for: field.frame)
        hideCardIfMouseLeft()

        guard enabled, Self.apps.contains(field.app.bundleIdentifier ?? "") else {
            handle.model.liveOn = false
            clearMarks(); return
        }
        handle.model.liveOn = true
        if field.value != lastValue {
            // Field emptied after having text: the message was sent.
            if let last = lastValue, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Metrics.record("message_sent", ["inFlight": inFlight, "issuesShown": current?.edits.count ?? 0,
                                                "unchecked": renderedValue != last])
            }
            lastValue = field.value
            lastChange = .now
            if renderedValue != field.value { clearMarks() }
            return
        }
        if field.frame != lastFrame, renderedValue == field.value {  // window moved/resized
            lastFrame = field.frame
            render(field)
            return
        }
        lastFrame = field.frame
        guard Date().timeIntervalSince(lastChange) >= Self.pause, renderedValue != field.value,
              !field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        render(field)
        checkPending(field)
    }

    private func sentences(_ text: String) -> [(range: NSRange, text: String, key: String)] {
        var out: [(NSRange, String, String)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { sub, range, _, _ in
            guard let sub else { return }
            let key = sub.trimmingCharacters(in: .whitespacesAndNewlines)
            if key.filter(\.isLetter).count >= 3 { out.append((range, sub, key)) }
        }
        return out
    }

    /// One request per pause with every new sentence (one per line), not one per sentence.
    private func checkPending(_ field: TextAccess.FocusedField) {
        guard !inFlight else { return }
        let snap = TextAccess.snapshot(of: field)
        let pending = sentences(field.value).filter { cache[$0.key] == nil }
        guard !pending.isEmpty else { return }
        inFlight = true
        handle.model.checking = true
        let provider = currentProvider()
        let prompt = PromptBuilder(mode: .correct, tone: Tone.default(forBundleID: field.app.bundleIdentifier),
                                   explanationLanguage: Prefs.explanationLang, live: true)
        // Join the sentences, shifting each one's protected ranges (mentions) into the joined text.
        var joined = ""
        var protected: [NSRange] = []
        for s in pending {
            let base = (joined as NSString).length
            for r in snap.protected where NSIntersectionRange(r, s.range).length == r.length {
                protected.append(NSRange(location: base + r.location - s.range.location, length: r.length))
            }
            joined += s.text.replacingOccurrences(of: "\n", with: " ") + "\n"
        }
        let masked = MentionMasker.mask(joined, protected: protected)
        let chars = (joined as NSString).length
        Task { @MainActor in
            let start = Date()
            var edits: [Edit] = []
            do {
                let raw = try await provider.complete(system: PromptBuilder.system, user: prompt.user(masked.text))
                let c = try CorrectionParser.parse(raw)
                edits = EditPlanner.prepare(c.edits, placeholders: masked.placeholders)
                    .filter { $0.kind == .correctness || $0.kind == .clarity }
            } catch {
                Log.info("live failed: \(error.localizedDescription)")
            }
            // Give each edit to the sentence that contains it.
            var bySentence: [String: [Edit]] = Dictionary(uniqueKeysWithValues: pending.map { ($0.key, []) })
            for e in edits {
                if let s = pending.first(where: { $0.text.contains(e.original) }) { bySentence[s.key, default: []].append(e) }
            }
            for (k, v) in bySentence { cache[k] = v }
            let secs = Date().timeIntervalSince(start)
            Log.info("live: \(pending.count) sentences, \(edits.count) edits in \(String(format: "%.1f", secs))s")
            Metrics.record("live_check", ["sentences": pending.count, "chars": chars, "edits": edits.count,
                                          "ms": Int(secs * 1000)])
            inFlight = false
            handle.model.checking = false
            if let f = TextAccess.focusedField(), f.value == field.value, !suspended { render(f) }
        }
    }

    // MARK: Rendering

    private func render(_ field: TextAccess.FocusedField) {
        let snap = TextAccess.snapshot(of: field)
        var planned: [PlannedEdit] = []
        var sentenceOf: [Int: String] = [:]
        for s in sentences(field.value) {
            guard let edits = cache[s.key] else { continue }
            let visible = edits.filter { !ignored.contains("\(s.key)|\($0.original)") }
            let protected = snap.protected.compactMap { r -> NSRange? in
                NSIntersectionRange(r, s.range).length == r.length ? NSRange(location: r.location - s.range.location, length: r.length) : nil
            }
            for p in EditPlanner.plan(text: s.text, edits: visible, protected: protected) {
                let abs = NSRange(location: s.range.location + p.range.location, length: p.range.length)
                planned.append(PlannedEdit(range: abs, replacement: p.replacement, explanation: p.explanation, category: p.category))
                sentenceOf[abs.location] = s.key
            }
        }
        renderedValue = field.value
        handle.model.count = planned.count
        handle.model.worst = [EditCategory.correctness, .clarity, .tone, .engagement].first { c in planned.contains { $0.category == c } }

        guard !planned.isEmpty else { current = nil; overlay.hide(); card.hide(); return }
        let rects = TextAccess.rects(for: planned, in: snap)
        current = (snap, planned, rects, sentenceOf)
        overlay.show(planned.compactMap { e in rects[e.range.location].map { (id: e.range.location, axRect: $0, color: Ink.nsColor(e.category)) } })
    }

    private func clearMarks() {
        overlay.hide()
        card.hide()
        current = nil
        renderedValue = nil
        handle.model.count = 0
        handle.model.worst = nil
    }

    // MARK: Card

    private func hovered(_ id: Int?) {
        guard let id, let cur = current, let e = cur.edits.first(where: { $0.range.location == id }),
              let rect = cur.rects[id] else { return }
        if card.shownID != id {
            card.show(e, fieldText: cur.snap.fieldText, wordRect: rect, language: Prefs.explanationLang)
        }
    }

    private func hideCardIfMouseLeft() {
        guard card.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        if !card.frame.insetBy(dx: -10, dy: -10).contains(mouse), overlay.hoveredID == nil {
            card.hide()
        }
    }

    private func apply(_ e: PlannedEdit) {
        guard let cur = current, let key = cur.sentenceOf[e.range.location] else { return }
        card.hide()
        overlay.hide()
        let result = EditPlanner.apply([e], to: cur.snap.fieldText)
        // The fixed sentence keeps its other suggestions without asking the model again.
        let removed = (cur.snap.fieldText as NSString).substring(with: e.range)
        if let edits = cache[key] {
            let newKey = key.replacingOccurrences(of: removed, with: e.replacement)
            cache[newKey] = edits.filter { $0.original != removed }
        }
        Metrics.record("suggestion_applied", ["source": "live", "category": e.category.rawValue])
        Task { @MainActor in
            let ok = await TextAccess.apply([e], to: cur.snap, result: result)
            Log.info("live apply \(ok ? "ok" : "mismatch")")
        }
    }

    private func ignore(_ e: PlannedEdit) {
        guard let cur = current, let key = cur.sentenceOf[e.range.location] else { return }
        ignored.insert("\(key)|\((cur.snap.fieldText as NSString).substring(with: e.range))")
        Metrics.record("suggestion_ignored", ["source": "live", "category": e.category.rawValue])
        card.hide()
        if let f = TextAccess.focusedField() { render(f) }
    }
}
