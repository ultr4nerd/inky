import AppKit
import ApplicationServices
import Carbon.HIToolbox
import InkyCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: HotKey?
    private let panel = PanelController()
    private let overlay = UnderlineOverlay()
    /// Word positions of the panel's edits in the field, for the ink splash after applying.
    private var panelRects: [Int: CGRect] = [:]
    private let live = LiveController()
    private var settingsWindow: NSWindow?

    private var provider: Provider?
    private var providerSignature = ""
    private var snapshot: FieldSnapshot?
    private var task: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        LoginItem.setUpIfInstalled()
        setUpMenu()
        hotKey = HotKey { [weak self] in Task { @MainActor in self?.hotKeyPressed() } }
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        // Clicking anywhere else closes the panel, like a popover.
        panel.onOutsideClick = { [weak self] in
            guard let self, !self.panel.model.applying else { return }
            self.task?.cancel()
            self.hidePanel()
        }
        panel.model.onApply = { [weak self] in self?.applyResult() }
        panel.model.onCancel = { [weak self] in self?.close() }
        live.handle.onClick = { [weak self] in self?.hotKeyPressed() }
        live.start()
        panel.model.onHover = { [weak self] id in self?.overlay.highlight(id) }
        overlay.onHover = { [weak self] id in self?.panel.model.hovered = id }
        panel.model.onMode = { [weak self] m in
            guard let self, self.snapshot != nil, m != self.panel.model.mode || m == .custom else { return }
            self.panel.model.mode = m
            self.run()
        }
        Log.info("launched; trusted=\(AXIsProcessTrusted()) hotkey=\(hotKey?.mechanism ?? "none")")
        if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) {
            NSLog("Inky: waiting for Accessibility permission")
        }
        // The panel belongs to the field it was opened for: close it if the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, !self.panel.model.applying,
                      app?.processIdentifier != self.snapshot?.app.processIdentifier,
                      app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self.task?.cancel()
                self.hidePanel()
            }
        }
        if CommandLine.arguments.contains("--demo-panel") { showDemoPanel() }
        if CommandLine.arguments.contains("--test-underlines") { testUnderlines() }
        // Start `claude` now so the first check is fast.
        if let claude = currentProvider() as? ClaudeCodeProvider {
            Task { await claude.warmUp(system: PromptBuilder.system) }
        }
    }

    // MARK: Menu

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Brand.glyph
        let menu = NSMenu()
        menu.addItem(withTitle: "Check text  (⌃⌥I)", action: #selector(checkFromMenu), keyEquivalent: "").target = self
        let status = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        status.target = self
        status.tag = 99
        menu.addItem(status)
        let liveItem = NSMenuItem(title: "Live checking in Slack (sends text as you type)", action: #selector(toggleLive), keyEquivalent: "")
        liveItem.target = self
        liveItem.tag = 98
        menu.addItem(liveItem)
        menu.addItem(withTitle: "Stats…", action: #selector(showStats), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Quit Inky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func toggleLive() {
        let d = UserDefaults.standard
        let on = d.bool(forKey: LiveController.enabledKey)
        if !on {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Turn on live checking in Slack?"
            alert.informativeText = """
            While it's on, every sentence you type in Slack is sent to your AI provider (\(currentProvider().displayName)) \
            after you pause, without pressing anything. Check that this is OK with your company's policies.

            The ink drop next to the text field gets a ring while live checking is on.
            """
            alert.addButton(withTitle: "Turn On")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        d.set(!on, forKey: LiveController.enabledKey)
        Metrics.record("live_toggled", ["on": !on])
    }

    @objc private func showStats() {
        let ev = Metrics.events(since: Date().addingTimeInterval(-7 * 86400))
        func count(_ e: String) -> Int { ev.filter { $0["event"] as? String == e }.count }
        func sum(_ e: String, _ k: String) -> Int { ev.filter { $0["event"] as? String == e }.reduce(0) { $0 + ($1[k] as? Int ?? 0) } }
        let sentences = sum("live_check", "sentences"), suggestions = sum("live_check", "edits")
        let applied = count("suggestion_applied"), ignored = count("suggestion_ignored")
        let sent = ev.filter { $0["event"] as? String == "message_sent" }
        let late = sent.filter { ($0["inFlight"] as? Bool) == true || ($0["unchecked"] as? Bool) == true }.count
        let llm = ev.filter { $0["event"] as? String == "llm" }
        let cost = llm.reduce(0.0) { $0 + ($1["costUSD"] as? Double ?? 0) }
        let out = llm.reduce(0) { $0 + ($1["output"] as? Int ?? 0) }
        let pct = { (a: Int, b: Int) in b == 0 ? "–" : "\(Int((Double(a) / Double(b) * 100).rounded()))%" }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Inky · last 7 days"
        alert.informativeText = """
        Live checking
        • Sentences checked: \(sentences)
        • Suggestions: \(suggestions) (applied \(applied), dismissed \(ignored))
        • Applied per sentence checked: \(pct(applied, sentences))
        • Messages sent: \(sent.count), before Inky finished: \(late) (\(pct(late, sent.count)))

        Model usage
        • Requests: \(llm.count) · output tokens: \(out)
        • Cost reported by the CLI (API-equivalent): $\(String(format: "%.3f", cost))
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show File")
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([Metrics.fileURL]) }
    }

    @objc private func checkFromMenu() { hotKeyPressed() }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Inky Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Debug: underline the first two words of Slack's focused composer for 8 s and log the rects.
    private func testUnderlines() {
        guard let slack = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tinyspeck.slackmacgap").first else { return }
        let appEl = AXUIElementCreateApplication(slack.processIdentifier)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var found: AXUIElement?
        func walk(_ e: AXUIElement, _ d: Int) {
            if d > 40 || found != nil { return }
            if TextAccess.attr(e, kAXRoleAttribute) as? String == "AXTextArea", TextAccess.attr(e, kAXFocusedAttribute) as? Bool == true { found = e; return }
            for c in (TextAccess.attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
        }
        if let w = TextAccess.attr(appEl, kAXFocusedWindowAttribute) { walk(w as! AXUIElement, 0) }
        guard let el = found, let value = TextAccess.attr(el, kAXValueAttribute) as? String else { Log.info("test: no field"); return }
        let ns = value as NSString
        let words = value.split(separator: " ").prefix(4).map(String.init)
        let edits = words.enumerated().compactMap { i, w -> PlannedEdit? in
            let r = ns.range(of: w); guard r.location != NSNotFound, i % 2 == 0 || i == 3 else { return nil }
            return PlannedEdit(range: r, replacement: w, explanation: "", category: EditCategory.allCases[i % 4])
        }
        let snap = FieldSnapshot(app: slack, element: el, fieldText: value, target: NSRange(location: 0, length: ns.length),
                                 protected: [], viaClipboard: false, anchor: nil)
        let rects = TextAccess.rects(for: edits, in: snap)
        Log.info("test underlines: \(rects.count)/\(edits.count) \(rects.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })")
        overlay.show(edits.compactMap { e in rects[e.range.location].map { (id: e.range.location, axRect: $0, color: Ink.nsColor(e.category)) } })
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.overlay.hide() }
    }

    /// Debug: `Inky --demo-panel` shows a sample result so the panel can be checked visually.
    private func showDemoPanel() {
        let m = panel.model
        m.original = "this are a test, can you sent me the file?"
        m.tone = .casualProfessional
        m.providerName = "Claude Haiku"
        m.appName = "Slack"
        m.language = Prefs.explanationLang
        let ns = m.original as NSString
        m.edits = [
            PlannedEdit(range: ns.range(of: "this are"), replacement: "This is", explanation: "«this» es singular, así que va con «is». Y la oración empieza con mayúscula.", category: .correctness),
            PlannedEdit(range: ns.range(of: "sent"), replacement: "send", explanation: "Después de «can» el verbo va en forma base.", category: .correctness),
            PlannedEdit(range: ns.range(of: "the file"), replacement: "the file when you get a chance", explanation: "Suaviza la petición para que no suene a orden.", category: .tone),
        ]
        m.detectedTone = "directo · un poco brusco"
        m.state = .result
        panel.show(anchor: CGRect(x: 429, y: 829, width: 1061, height: 34))
    }

    /// Not animated when Inky is about to type into the app: the panel must stop being the
    /// key window right away so no keystroke lands in it.
    private func hidePanel(animated: Bool = true) {
        live.suspended = false
        live.handle.model.checking = false
        panel.model.applying = false
        overlay.hide(forget: true)
        panel.hide(animated: animated)
        panel.model.showCustom = false
    }

    // MARK: Flow

    private func currentProvider() -> Provider {
        let sig = Prefs.providerSignature
        if provider == nil || sig != providerSignature {
            provider = Prefs.makeProvider()
            providerSignature = sig
        }
        return provider!
    }

    private func hotKeyPressed() {
        Log.info("hotkey pressed; front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") trusted=\(AXIsProcessTrusted()) panelVisible=\(panel.isVisible)")
        guard !panel.isVisible else { return }
        panel.model.applying = false
        guard AXIsProcessTrusted() else {
            panel.model.state = .error("Inky needs Accessibility permission (System Settings → Privacy & Security → Accessibility).")
            panel.show(anchor: nil)
            return
        }
        panel.model.mode = .correct
        panel.model.language = Prefs.explanationLang
        panel.model.appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        do {
            let snap = try TextAccess.read()
            snapshot = snap
            Log.info("read ok; chars=\(snap.target.length) protected=\(snap.protected.count) clipboard=\(snap.viaClipboard) anchor=\(snap.anchor.map { "\($0)" } ?? "nil")")
            panel.model.tone = Tone.default(forBundleID: snap.app.bundleIdentifier)
            live.suspended = true
            run()
            panel.show(anchor: snap.anchor)
        } catch {
            snapshot = nil
            Log.info("read failed: \(error.localizedDescription)")
            panel.model.state = .error(error.localizedDescription)
            panel.show(anchor: nil)
        }
    }

    private func run() {
        guard let snap = snapshot else { return }
        let model = panel.model
        let provider = currentProvider()
        model.providerName = provider.displayName
        model.original = snap.targetText
        model.edits = []
        model.state = .loading
        model.detectedTone = nil
        model.hovered = nil
        model.applying = false
        model.focused = 0
        panelRects = [:]
        overlay.hide(forget: true)
        live.handle.model.checking = true   // the drop breathes while the panel waits
        let prompt = PromptBuilder(mode: model.mode, tone: model.tone, explanationLanguage: Prefs.explanationLang,
                                   customInstruction: model.customInstruction)
        let masked = MentionMasker.mask(snap.targetText, protected: snap.protected)

        task?.cancel()
        task = Task { @MainActor in
            do {
                let raw = try await provider.complete(system: PromptBuilder.system, user: prompt.user(masked.text))
                guard !Task.isCancelled else { return }
                live.handle.model.checking = false
                let correction = try CorrectionParser.parse(raw)
                let edits = EditPlanner.prepare(correction.edits, placeholders: masked.placeholders)
                model.edits = EditPlanner.plan(text: snap.targetText, edits: edits, protected: snap.protected)
                model.detectedTone = correction.tone
                model.state = model.edits.isEmpty ? .noChanges : .result
                // Underline the words in the field itself (word-level modes only).
                if model.mode.isPrimary, model.mode != .translate, !model.edits.isEmpty {
                    let rects = TextAccess.rects(for: model.edits, in: snap)
                    panelRects = rects
                    overlay.show(model.edits.compactMap { e in
                        rects[e.range.location].map { (id: e.range.location, axRect: $0, color: Ink.nsColor(e.category)) }
                    })
                    Log.info("underlines \(rects.count)/\(model.edits.count)")
                }
                Log.info("result; edits=\(model.edits.count)")
                if model.edits.isEmpty {
                    try? await Task.sleep(for: .seconds(1.2))
                    if case .noChanges = model.state { hidePanel() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                live.handle.model.checking = false
                Log.info("provider failed: \(error.localizedDescription)")
                model.state = .error(error.localizedDescription)
            }
        }
    }

    private func applyResult() {
        guard let snap = snapshot, case .result = panel.model.state, !panel.model.applying else { return }
        let edits = panel.model.edits
        let result = EditPlanner.apply(edits, to: snap.targetText)
        let mode = panel.model.mode
        let rects = panelRects
        // A beat for the highlights to soak in and the button to turn into a check.
        panel.model.applying = true
        let beat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.5
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(beat))
            hidePanel(animated: false)
            let ok = await TextAccess.apply(edits, to: snap, result: result)
            if ok {
                for (i, e) in edits.sorted(by: { $0.range.location < $1.range.location }).enumerated() {
                    guard let r = rects[e.range.location] else { continue }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.07) {
                        UnderlineOverlay.splash(at: r, color: Ink.nsColor(e.category))
                    }
                }
                live.handle.model.flashDone()
            }
            Log.info("apply \(ok ? "ok" : "mismatch")")
            Metrics.record("panel_applied", ["edits": edits.count, "mode": mode.rawValue, "ok": ok])
            if !ok {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result, forType: .string)
                panel.model.applying = false
                panel.model.state = .error("Couldn't apply cleanly. The corrected text is on your clipboard.")
                panel.show(anchor: snap.anchor)
            }
            if UserDefaults.standard.bool(forKey: Prefs.historyEnabled) {
                HistoryStore.append(HistoryEntry(date: .now, app: snap.app.bundleIdentifier, mode: mode,
                                                 original: snap.targetText, corrected: result,
                                                 edits: edits.map { Edit(original: (snap.targetText as NSString).substring(with: $0.range),
                                                                         replacement: $0.replacement, explanation: $0.explanation) }))
            }
        }
    }

    private func close() {
        task?.cancel()
        hidePanel()
        snapshot?.app.activate()
    }

    /// Returns true when the key was handled.
    private func handleKey(_ e: NSEvent) -> Bool {
        if panel.model.applying { return true }   // Inky is about to type; swallow keys
        let cmd = e.modifierFlags.contains(.command)
        // While typing a custom instruction, let the text field have the keys (except Esc).
        if panel.model.showCustom {
            if Int(e.keyCode) == kVK_Escape { panel.model.showCustom = false; return true }
            return false
        }
        if cmd, Int(e.keyCode) == kVK_ANSI_K { panel.model.showCustom = true; return true }
        switch Int(e.keyCode) {
        case kVK_Escape: close()
        case kVK_Return, kVK_ANSI_KeypadEnter: applyResult()
        case kVK_Tab:
            guard snapshot != nil else { return true }
            panel.model.mode = e.modifierFlags.contains(.shift) ? panel.model.mode.previous() : panel.model.mode.next()
            run()
        case kVK_ANSI_E where cmd: panel.model.showExplanations.toggle()
        case kVK_LeftArrow, kVK_RightArrow:
            let n = panel.model.edits.count
            guard n > 1, case .result = panel.model.state else { return false }
            let step = Int(e.keyCode) == kVK_RightArrow ? 1 : -1
            panel.model.hovered = nil
            panel.model.focused = ((panel.model.focused + step) % n + n) % n
        case kVK_ANSI_C where cmd:
            guard let snap = snapshot, case .result = panel.model.state else { return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(EditPlanner.apply(panel.model.edits, to: snap.targetText), forType: .string)
            close()
        default: return false
        }
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if AXIsProcessTrusted() { hotKey?.retryTapIfNeeded() }
        menu.item(withTag: 98)?.state = UserDefaults.standard.bool(forKey: LiveController.enabledKey) ? .on : .off
        guard let item = menu.item(withTag: 99) else { return }
        let trusted = AXIsProcessTrusted()
        let hotkeyOK = hotKey?.registered == true
        item.title = trusted
            ? (hotkeyOK ? "✓ Ready" : "⚠︎ Shortcut ⌃⌥I is taken by another app")
            : "⚠︎ Grant Accessibility permission…"
        item.isEnabled = !trusted
    }
}
