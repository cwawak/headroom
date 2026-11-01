import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), AntigravityProvider()]
    private let preferences = PreferencesStore()
    private let resetDetector = ResetDetector()

    private var watcher: FileWatcher?
    private var statusItem: NSStatusItem!
    private var pending: DispatchWorkItem?
    private var lastScan: Date = .distantPast
    private var safetyTimer: Timer?
    private var snapshots: [ProviderID: Snapshot] = [:]

    /// Built once and kept, so opening the menu never destroys a view mid-animation.
    private var rowViews: [ProviderID: [QuotaWindow: MenuRowView]] = [:]
    private var metaItems: [ProviderID: NSMenuItem] = [:]

    private var installed: [ProviderID] = []
    private var displayOrder: [ProviderID] { [.codex, .claude, .antigravity] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        resetDetector.requestAuthorization()

        installed = displayOrder.filter { id in
            guard let p = providers.first(where: { $0.id == id }) else { return false }
            return p.isInstalled() && p.canReportUsage
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " ···"
        statusItem.menu = buildMenu()

        let roots = providers.filter { $0.isInstalled() }.flatMap { $0.watchRoots() }
        watcher = FileWatcher(roots: roots) { [weak self] in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        watcher?.start()

        // Safety net for anything FSEvents misses. Deliberately slow — the
        // watcher is the real mechanism.
        safetyTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        refresh()

        // `--demo-calibrate` opens the calibration sheet so its layout can be
        // checked without a human clicking through to it.
        if ProcessInfo.processInfo.arguments.contains("--demo-calibrate") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                MainActor.assumeIsolated {
                    NSApp.activate(ignoringOtherApps: true)
                    self?.calibrateAction()
                }
            }
        }

        // `--demo-menu` pops the menu open on its own so the layout can be
        // screenshotted and checked without a human clicking it.
        if ProcessInfo.processInfo.arguments.contains("--demo-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                MainActor.assumeIsolated { self?.statusItem.button?.performClick(nil) }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        safetyTimer?.invalidate()
    }

    // MARK: - Menu lifecycle

    /// Opening the menu is an explicit action, so it's the one moment motion is
    /// justified: re-read the logs and replay every capsule from empty.
    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        for rows in rowViews.values { for view in rows.values { view.replay() } }
    }

    func menuDidClose(_ menu: NSMenu) {
        for rows in rowViews.values { for view in rows.values { view.stop() } }
    }

    // MARK: - Refresh

    /// Throttled, not just debounced.
    private static let minimumScanInterval: TimeInterval = 6

    private func scheduleRefresh() {
        pending?.cancel()
        let since = Date().timeIntervalSince(lastScan)
        let delay = max(0.4, Self.minimumScanInterval - since)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refresh() {
        lastScan = Date()
        let list = providers
        Task.detached(priority: .utility) {
            var out: [ProviderID: Snapshot] = [:]
            for p in list where p.isInstalled() {
                if let snap = try? p.snapshot() { out[p.id] = snap }
            }
            let result = out
            await MainActor.run { [weak self] in self?.apply(result) }
        }
    }

    private func apply(_ snaps: [ProviderID: Snapshot]) {
        snapshots = snaps
        _ = resetDetector.inspect(snapshots: snaps)

        for id in installed {
            guard let snap = snaps[id] else { continue }
            for window in QuotaWindow.allCases {
                guard let view = rowViews[id]?[window] else { continue }
                let reading = snap.readings[window] ?? .unavailable(reason: "no data")
                view.configure(reading: reading, detail: detail(for: reading))
            }
            metaItems[id]?.attributedTitle = secondary(metaLine(for: snap), indent: 21)
        }

        // Candidates for status presentation: respect hidden providers and focus on weekly
        let candidates = installed
            .filter { !preferences.isProviderHidden($0) }
            .compactMap { id -> (ProviderID, Double, Date?)? in
                guard let snap = snaps[id] else { return nil }
                // User requirement: Focus on weekly, falling back to worst available if weekly has no valid reading
                let weeklyReading = snap.readings[.long]
                let reading = (weeklyReading?.percentRemaining != nil) ? weeklyReading! : worstWindow(of: snap).1
                guard let left = reading.percentRemaining else { return nil }
                return (id, left, snap.sourceDate)
            }

        let recent = candidates
            .filter { $0.2.map { Date().timeIntervalSince($0) < 1800 } ?? false }
            .max { ($0.2 ?? .distantPast) < ($1.2 ?? .distantPast) }
        let chosen = recent ?? candidates.min { $0.1 < $1.1 }

        setStatusPresentation(chosen.map { ($0.0, $0.1) }, isActive: recent != nil)
    }

    private func worstWindow(of snap: Snapshot) -> (QuotaWindow, Reading) {
        let isShortHidden = preferences.isShortLimitHidden(for: snap.provider)
        let windows: [QuotaWindow] = isShortHidden ? [.long] : QuotaWindow.allCases

        let ranked = windows.compactMap { w -> (QuotaWindow, Reading, Double)? in
            guard let r = snap.readings[w], let left = r.percentRemaining else { return nil }
            return (w, r, left)
        }.sorted { $0.2 < $1.2 }
        if let top = ranked.first { return (top.0, top.1) }
        return (.long, snap.readings[.long] ?? snap.readings[.short] ?? .unavailable(reason: "no data"))
    }

    // MARK: - Status item

    private func setStatusPresentation(_ chosen: (ProviderID, Double)?, isActive: Bool) {
        guard let button = statusItem.button else { return }

        guard let (id, left) = chosen else {
            button.image = symbol(0)
            button.title = " —"
            button.toolTip = "Headroom — no data"
            button.setAccessibilityLabel("Headroom, no data")
            return
        }
        button.image = symbol(left / 100)
        button.title = " \(id.displayName) \(Int(left.rounded()))%"
        button.toolTip = isActive
            ? "\(id.displayName): \(Int(left.rounded()))% left — the agent you're using now"
            : "\(id.displayName): \(Int(left.rounded()))% left — least of any agent"
        button.setAccessibilityLabel("Headroom, \(id.displayName) \(Int(left.rounded())) percent left")
    }

    private func symbol(_ value: Double) -> NSImage? {
        let image = NSImage(systemSymbolName: "gauge.with.dots.needle.bottom.0percent",
                            variableValue: max(0, min(1, value)),
                            accessibilityDescription: "Headroom")
        image?.isTemplate = true
        return image
    }

    // MARK: - Menu construction

    private func rebuildMenu() {
        statusItem.menu = buildMenu()
        apply(snapshots)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        rowViews.removeAll()
        metaItems.removeAll()

        for id in installed where !preferences.isProviderHidden(id) {
            buildAgentRows(for: id, into: menu)
        }

        buildSilentAgents(into: menu)
        buildPreferencesMenu(into: menu)
        buildStandardActions(into: menu)

        menu.items.forEach { if $0.action != nil { $0.target = self } }
        return menu
    }

    private func buildAgentRows(for id: ProviderID, into menu: NSMenu) {
        let header = NSMenuItem()
        header.attributedTitle = sectionHeader("\(id.displayName) remaining")
        header.isEnabled = false
        menu.addItem(header)

        var views: [QuotaWindow: MenuRowView] = [:]
        let hideShort = preferences.isShortLimitHidden(for: id)

        for window in QuotaWindow.allCases {
            if window == .short && hideShort { continue }
            let view = MenuRowView(title: window == .short ? "5 hours" : "This week")
            let item = NSMenuItem()
            item.view = view
            item.isEnabled = true
            menu.addItem(item)
            views[window] = view
        }
        rowViews[id] = views

        let meta = NSMenuItem()
        meta.attributedTitle = secondary("", indent: 21)
        meta.isEnabled = false
        menu.addItem(meta)
        metaItems[id] = meta

        if id == .claude {
            let item = NSMenuItem(title: "Calibrate from Claude's usage page…",
                                  action: #selector(calibrateAction), keyEquivalent: "")
            item.toolTip = "Claude → Settings → Usage shows the real percentages. "
                + "Entering them anchors this estimate to them."
            item.isEnabled = true
            item.indentationLevel = 1
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private func buildSilentAgents(into menu: NSMenu) {
        let silent = providers.filter {
            (!preferences.isProviderHidden($0.id)) && (!$0.canReportUsage || !$0.isInstalled())
        }
        guard !silent.isEmpty else { return }

        for p in silent {
            let reason = (try? p.snapshot())?.readings[.short].flatMap { r -> String? in
                if case .unavailable(let why) = r { return why }
                return nil
            } ?? "not detected"
            let item = NSMenuItem()
            item.attributedTitle = secondary("\(p.id.displayName) — \(reason)", indent: 21)
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    private func buildPreferencesMenu(into menu: NSMenu) {
        let prefsItem = NSMenuItem(title: "Preferences", action: nil, keyEquivalent: "")
        let subMenu = NSMenu()
        subMenu.autoenablesItems = false

        // Toggle Providers
        let providersHeader = NSMenuItem(title: "Show Providers", action: nil, keyEquivalent: "")
        providersHeader.isEnabled = false
        subMenu.addItem(providersHeader)

        for provider in ProviderID.allCases {
            let isVisible = !preferences.isProviderHidden(provider)
            let item = NSMenuItem(
                title: "  \(provider.displayName)",
                action: #selector(toggleProviderAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider.rawValue
            item.state = isVisible ? .on : .off
            item.isEnabled = true
            subMenu.addItem(item)
        }

        subMenu.addItem(.separator())

        // Toggle 5-Hour Limits
        let limitsHeader = NSMenuItem(title: "Hide 5-Hour Limits", action: nil, keyEquivalent: "")
        limitsHeader.isEnabled = false
        subMenu.addItem(limitsHeader)

        for provider in ProviderID.allCases {
            let isHidden = preferences.isShortLimitHidden(for: provider)
            let item = NSMenuItem(
                title: "  \(provider.displayName) 5-Hour Limit",
                action: #selector(toggleShortLimitAction(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = provider.rawValue
            item.state = isHidden ? .on : .off
            item.isEnabled = true
            subMenu.addItem(item)
        }

        prefsItem.submenu = subMenu
        menu.addItem(prefsItem)
        menu.addItem(.separator())
    }

    @objc private func toggleProviderAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        let currentHidden = preferences.isProviderHidden(provider)
        preferences.setProviderHidden(provider, hidden: !currentHidden)
        rebuildMenu()
    }

    @objc private func toggleShortLimitAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = ProviderID(rawValue: raw) else { return }
        let currentHidden = preferences.isShortLimitHidden(for: provider)
        preferences.setShortLimitHidden(for: provider, hidden: !currentHidden)
        rebuildMenu()
    }

    private func buildStandardActions(into menu: NSMenu) {
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.isEnabled = true
        menu.addItem(refresh)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Headroom", action: #selector(quitAction), keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)
    }

    // MARK: - Text

    private func sectionHeader(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
    }

    private func secondary(_ text: String, indent: CGFloat) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .paragraphStyle: p
        ])
    }

    private func detail(for reading: Reading) -> String {
        switch reading {
        case .authoritative:
            return "\(Int((reading.percentRemaining ?? 0).rounded()))% left"
        case .estimated:
            return "~\(Int((reading.percentRemaining ?? 0).rounded()))% left"
        case .unavailable:
            return "—"
        }
    }

    private func metaLine(for snap: Snapshot) -> String {
        var bits: [String] = []

        let exact = QuotaWindow.allCases.contains { snap.readings[$0]?.isExact == true }
        if exact {
            if let plan = snap.planLabel { bits.append(plan) }
            bits.append("exact")
        } else {
            bits.append(snap.planLabel == "calibrated" ? "estimated · calibrated"
                                                       : "estimated · uncalibrated")
        }

        if let banked = snap.bankedResets, banked > 0 {
            bits.append("\(banked) banked reset\(banked == 1 ? "" : "s")")
        }

        if let resets = QuotaWindow.allCases.compactMap({ snap.readings[$0]?.resetsAt }).min() {
            bits.append("resets \(RelativeDateTimeFormatter().localizedString(for: resets, relativeTo: Date()))")
        }
        if let age = snap.staleness, age > 1800 {
            let mins = Int(age / 60)
            bits.append(mins < 90 ? "stale \(mins)m" : "stale \(Int((age / 3600).rounded()))h")
        }
        return bits.joined(separator: " · ")
    }

    // MARK: - Calibration

    @objc private func calibrateAction() {
        guard let snap = snapshots[.claude] else { return }
        let calibration = CalibrationStore.load()

        let alert = NSAlert()
        alert.messageText = "Calibrate Claude usage"
        alert.informativeText = """
            Open Claude → Settings → Usage. Enter the two "% used" figures, and \
            set the weekly reset to match the "Resets …" line shown there.

            This also captures usage from claude.ai and the Claude desktop app, which \
            share your plan limit but never appear in the local Claude Code logs.
            """
        alert.addButton(withTitle: "Calibrate")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 88))
        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .trailing

        func row(_ caption: String, _ control: NSView) -> NSStackView {
            let r = NSStackView()
            r.orientation = .horizontal
            r.spacing = 8
            r.addArrangedSubview(NSTextField(labelWithString: caption))
            r.addArrangedSubview(control)
            return r
        }

        func percentField() -> NSTextField {
            let input = NSTextField(string: "")
            input.placeholderString = "% used"
            input.widthAnchor.constraint(equalToConstant: 76).isActive = true
            return input
        }

        let shortField = percentField()
        let longField = percentField()

        let weekdayPopup = NSPopUpButton()
        weekdayPopup.addItems(withTitles: Calendar.current.weekdaySymbols)
        weekdayPopup.selectItem(at: min(6, max(0, calibration.weeklyResetWeekday - 1)))
        weekdayPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true

        let hourPopup = NSPopUpButton()
        hourPopup.addItems(withTitles: (0..<24).map { h in
            let display = h % 12 == 0 ? 12 : h % 12
            return "\(display):00 \(h < 12 ? "AM" : "PM")"
        })
        hourPopup.selectItem(at: min(23, max(0, calibration.weeklyResetHour)))
        hourPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true

        let resetRow = NSStackView()
        resetRow.orientation = .horizontal
        resetRow.spacing = 6
        resetRow.addArrangedSubview(NSTextField(labelWithString: "Weekly resets:"))
        resetRow.addArrangedSubview(weekdayPopup)
        resetRow.addArrangedSubview(hourPopup)

        stack.addArrangedSubview(row("Current session:", shortField))
        stack.addArrangedSubview(row("Weekly (all models):", longField))
        stack.addArrangedSubview(resetRow)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = shortField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let newWeekday = weekdayPopup.indexOfSelectedItem + 1
        let newHour = hourPopup.indexOfSelectedItem
        let anchorMoved = newWeekday != calibration.weeklyResetWeekday
                       || newHour != calibration.weeklyResetHour

        var updated = calibration
        updated.weeklyResetWeekday = newWeekday
        updated.weeklyResetHour = newHour
        CalibrationStore.save(updated)

        let shortText = shortField.stringValue
        let longText = longField.stringValue
        let claude = providers.first { $0.id == .claude }
        let fallback = snap.rawWeighted

        Task.detached(priority: .userInitiated) {
            var raw = fallback
            if anchorMoved, let fresh = try? claude?.snapshot(), let r = fresh.rawWeighted {
                raw = r
            }
            let measured = raw
            await MainActor.run { [weak self] in
                guard let self, let measured else { return }
                var cal = CalibrationStore.load()
                var changed = false
                for (text, window) in [(shortText, QuotaWindow.short),
                                       (longText, QuotaWindow.long)] {
                    guard let v = Self.percent(from: text), let sum = measured[window] else { continue }
                    cal.calibrate(observedUsedPercent: v, weightedSum: sum, for: window)
                    changed = true
                }
                if changed { CalibrationStore.save(cal) }
                self.refresh()
            }
        }
    }

    /// Accepts "54", "54%", " 54 % " — people paste what they see.
    nonisolated static func percent(from text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned), v > 0, v <= 100 else { return nil }
        return v
    }

    @objc private func refreshAction() { refresh() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
