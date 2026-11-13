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
    private var settingsLanguage: ExplanationLanguage?

    private var provider: Provider?
    private var providerSignature = ""
    private var snapshot: FieldSnapshot?
    private var task: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        LoginItem.setUpIfInstalled()
        setUpMenu()
        installHotKey()
        NotificationCenter.default.addObserver(forName: .inkyShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow?.close(); self?.onboarding.show() }
        }
        NotificationCenter.default.addObserver(forName: .inkyShortcutChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installHotKey() }
        }
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }
        // Clicking anywhere else closes the panel, like a popover.
        panel.onOutsideClick = { [weak self] in
            guard let self, !self.panel.model.applying else { return }
            self.task?.cancel()
            self.hidePanel()
        }
        panel.model.onApply = { [weak self] in self?.applyResult() }
        panel.model.onRetry = { [weak self] in
            guard let self, self.snapshot != nil else { return }
            self.run()
        }
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
        Task { _ = await Usage.report() }   // warm the usage estimate for the popover and alerts
        if !UserDefaults.standard.bool(forKey: Onboarding.doneKey) || CommandLine.arguments.contains("--onboarding") || CommandLine.arguments.contains("--onboarding-step") {
            onboarding.show()
        }
        if CommandLine.arguments.contains("--demo-panel") { showDemoPanel() }
        if CommandLine.arguments.contains("--test-underlines") { testUnderlines() }
        // Start `claude` now so the first check is fast.
        if let claude = currentProvider() as? ClaudeCodeProvider {
            Task { await claude.warmUp(system: PromptBuilder.system) }
        }
    }

    /// The global shortcut from Settings (default ⌃⌥I).
    private func installHotKey() {
        hotKey?.invalidate()
        let d = UserDefaults.standard
        hotKey = HotKey(keyCode: d.integer(forKey: Prefs.hotkeyCode),
                        flags: CGEventFlags(rawValue: UInt64(d.integer(forKey: Prefs.hotkeyMods)))) { [weak self] in
            Task { @MainActor in self?.hotKeyPressed() }
        }
    }

    // MARK: Menu

    private let menuModel = MenuModel()
    private let onboarding = Onboarding()
    private lazy var popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.contentViewController = NSHostingController(rootView: MenuPopoverView(model: menuModel))
        return p
    }()
    /// The app that was in front before the popover opened (to give focus back).
    private var appBeforePopover: NSRunningApplication?

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = Brand.glyph
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        menuModel.onCheck = { [weak self] in
            guard let self else { return }
            self.popover.performClose(nil)
            self.appBeforePopover?.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.hotKeyPressed() }
        }
        menuModel.onToggleLive = { [weak self] on in
            if !on || LivePrivacy.confirm() { LivePrivacy.set(on) }
            self?.refreshMenu()
        }
        menuModel.onStats = { [weak self] in self?.popover.performClose(nil); self?.showStats() }
        menuModel.onSettings = { [weak self] in self?.popover.performClose(nil); self?.openSettings() }
        menuModel.onGrant = { [weak self] in self?.popover.performClose(nil); self?.openAccessibilitySettings() }
    }

    private func refreshMenu() {
        if AXIsProcessTrusted() { hotKey?.retryTapIfNeeded() }
        menuModel.trusted = AXIsProcessTrusted()
        menuModel.hotkeyOK = hotKey?.registered == true
        menuModel.shortcut = Prefs.shortcut
        menuModel.liveOn = UserDefaults.standard.bool(forKey: LiveController.enabledKey)
        menuModel.refreshStats()
        menuModel.provider = ProviderKind(rawValue: UserDefaults.standard.string(forKey: Prefs.provider) ?? "") ?? .claude
        menuModel.usage = Usage.last
        menuModel.liveWhere = Prefs.liveWhere
        Task { menuModel.usage = await Usage.report() }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        refreshMenu()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { appBeforePopover = front }
        NSApp.activate(ignoringOtherApps: true)   // so the transient popover closes on an outside click
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Inky · últimos 7 días", "Inky · last 7 days")
        alert.informativeText = L("""
        Revisión en vivo
        • Oraciones revisadas: \(sentences)
        • Sugerencias: \(suggestions) (aplicadas \(applied), ignoradas \(ignored))
        • Aplicadas por oración revisada: \(pct(applied, sentences))
        • Mensajes enviados: \(sent.count), antes de que Inky terminara: \(late) (\(pct(late, sent.count)))

        Uso del modelo
        • Peticiones: \(llm.count) · tokens de salida: \(out)
        • Costo reportado por la CLI (equivalente en API): $\(String(format: "%.3f", cost))
        """, """
        Live checking
        • Sentences checked: \(sentences)
        • Suggestions: \(suggestions) (applied \(applied), dismissed \(ignored))
        • Applied per sentence checked: \(pct(applied, sentences))
        • Messages sent: \(sent.count), before Inky finished: \(late) (\(pct(late, sent.count)))

        Model usage
        • Requests: \(llm.count) · output tokens: \(out)
        • Cost reported by the CLI (API-equivalent): $\(String(format: "%.3f", cost))
        """)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: L("Mostrar archivo", "Show File"))
        if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([Metrics.fileURL]) }
    }

    @objc private func openSettings() {
        // Rebuilt when the interface language changed (tab labels are AppKit).
        if settingsWindow == nil || settingsLanguage != Prefs.uiLang {
            settingsWindow?.close()
            settingsWindow = SettingsWindow.make()
            settingsLanguage = Prefs.uiLang
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
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
        m.language = Prefs.uiLang
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
        panel.model.canRetry = false
        guard AXIsProcessTrusted() else {
            panel.model.state = .error(L("Inky necesita el permiso de Accesibilidad (Ajustes del Sistema → Privacidad y seguridad → Accesibilidad).", "Inky needs Accessibility permission (System Settings → Privacy & Security → Accessibility)."))
            panel.show(anchor: nil)
            return
        }
        panel.model.mode = .correct
        panel.model.language = Prefs.uiLang
        panel.model.appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        do {
            let snap = try TextAccess.read()
            snapshot = snap
            Log.info("read ok; chars=\(snap.target.length) protected=\(snap.protected.count) clipboard=\(snap.viaClipboard) anchor=\(snap.anchor.map { "\($0)" } ?? "nil")")
            panel.model.tone = Prefs.tone(forBundleID: snap.app.bundleIdentifier)
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
                model.canRetry = true
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
                panel.model.state = .error(L("No se pudo aplicar limpio. El texto corregido está en tu portapapeles.", "Couldn't apply cleanly. The corrected text is on your clipboard."))
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
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if case .error = panel.model.state, panel.model.canRetry { run() } else { applyResult() }
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
