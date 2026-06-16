import AppKit
import SwiftUI

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteWindowController()

    private var state: CommandPaletteState?
    private var keyMonitor: Any?
    /// Last installed-apps scan, refreshed off the main actor on every open. Seeds
    /// the Applications section instantly so summoning the palette never blocks on
    /// a fresh `/Applications` walk; empty only before the very first scan returns.
    private var cachedApps: [InstalledApp] = []

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Toggle visibility: hide if already showing, otherwise show fresh.
    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    private func show() {
        let sections = collectSections(installedApps: cachedApps)
        prewarmIcons(for: sections)
        let hyperFlags = HyperKeyService.shared.hyperModifierFlags
        let pickerState = CommandPaletteState(sections: sections, hyperFlags: hyperFlags)
        self.state = pickerState

        let view = CommandPalettePicker(
            state: pickerState,
            onSelect: { [weak self] entry in
                self?.commit(entry)
            },
            onCancel: { [weak self] in
                self?.cancel()
            },
            onConfirm: { [weak self] in
                self?.confirmPending()
            },
            onRefreshRates: { [weak self] in
                self?.refreshRates()
            }
        )

        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host

        installKeyMonitor()
        positionAtTopCenter()
        // Activate the app BEFORE keying the window. Summoned from a global
        // hotkey, this `.accessory` app is still in the background, so
        // `makeKeyAndOrderFront` cannot make the panel the key window until the
        // app is frontmost. With no key window, SwiftUI's @FocusState can't
        // hold first responder on the search field, and the onAppear/onChange
        // re-focus path oscillates every runloop tick (visible flicker, no
        // typing) until the user clicks the field. Activating first lets the
        // deferred focus assignment land on an already-key window.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)

        // Refresh the installed-apps list OFF the main actor: the window is
        // already on screen, so the `/Applications` scan can never delay
        // summoning the palette. When it resolves, repopulate the Applications
        // section in place (the @Observable state re-renders) and warm the new
        // icons. Subsequent opens render instantly from the cache above.
        Task { [weak self, weak pickerState] in
            let apps = await Task.detached(priority: .userInitiated) {
                InstalledAppsScanner.scan()
            }.value
            guard let self else { return }
            self.cachedApps = apps
            guard let pickerState, self.state === pickerState, self.window?.isVisible == true else { return }
            let refreshed = self.collectSections(installedApps: apps)
            pickerState.updateSections(refreshed)
            self.prewarmIcons(for: refreshed)
        }
    }

    /// Warm the icon cache for every app-backed row off the main thread, so the
    /// first scroll into the Applications section finds resolved icons instead of
    /// cold-cache disk hits. Mirrors CommandPaletteRow.iconPath.
    private func prewarmIcons(for sections: [CommandPaletteSection]) {
        AppIconCache.prewarm(sections.flatMap(\.entries).compactMap { entry in
            switch entry.source {
            case .installedApp(_, let path): return path
            case .appShortcut(let id): return PanelStore.shared.binding(id: id)?.appPath
            case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile: return nil
            }
        })
    }

    /// Build the section groups shown in the palette. Sections with no
    /// matching entries are dropped before they reach the view. `installedApps`
    /// is supplied by the caller (cached / off-main scanned) so this stays a
    /// cheap, synchronous main-actor assembly with no filesystem work.
    private func collectSections(installedApps: [InstalledApp]) -> [CommandPaletteSection] {
        let store = PanelStore.shared
        var sections: [CommandPaletteSection] = []

        // Refresh hosts profiles once at palette open so the root name-search
        // section reflects the current set without a per-keystroke fetch.
        HostsManager.shared.reload()

        // Kick a currency-rates refresh (at most once per day) so inline currency
        // conversion has a fresh table. Fire-and-forget; the cached table is used
        // immediately and updated rows appear as the user keeps typing.
        Task { await CurrencyRatesService.shared.refreshIfStale() }

        let hasExternalDDC = DisplayBrightnessService.shared.displays.contains(where: \.supportsDDC)
        let commands = store.topLevelEntries.filter { entry in
            guard entry.isVisible else { return false }
            guard case .builtin(let item) = entry.source else { return false }
            switch item.kind {
            case .toggle, .action:
                return true
            case .brightnessControl, .submenu:
                // Only the option parents the palette drills into; App Shortcuts,
                // Window Layout and Port Manager keep their own flat sections.
                return CommandPaletteOptions.shouldListInPalette(item, hasExternalDDC: hasExternalDDC)
            case .hiddenHotkey:
                return false
            }
        }
        if !commands.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionCommands,
                entries: commands
            ))
        }

        let windowLayout = store.windowLayoutChildren.filter(\.isVisible)
        if !windowLayout.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionWindowLayout,
                entries: windowLayout
            ))
        }

        let appShortcuts = store.appShortcutChildren.filter(\.isVisible)
        let boundBundleIDs: Set<String> = Set(appShortcuts.compactMap { entry in
            guard case .appShortcut(let id) = entry.source,
                  let binding = store.binding(id: id) else { return nil }
            return binding.appBundleID
        })

        // Apps installed on the system but not bound to a hotkey are listed
        // after the bound rows in the same section so they're searchable from
        // the palette without polluting the menu-bar panel itself.
        let unboundOrder = Double(appShortcuts.count) * 100 + 1_000_000
        let installedExtras: [PanelEntry] = installedApps
            .filter { !boundBundleIDs.contains($0.bundleID) }
            .enumerated()
            .map { offset, app in
                PanelEntry(
                    id: PanelEntry.id(for: .installedApp(bundleID: app.bundleID, path: app.path)),
                    source: .installedApp(bundleID: app.bundleID, path: app.path),
                    displayOrder: unboundOrder + Double(offset),
                    isVisible: true,
                    hotkey: nil,
                    title: app.displayName,
                    subtitle: nil,
                    symbol: "app.fill",
                    kind: .submenu,
                    toggleState: nil,
                    permission: .notRequired
                )
            }

        let combined = appShortcuts + installedExtras
        if !combined.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionApplications,
                entries: combined
            ))
        }

        return sections
    }

    private func positionAtTopCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let topInset = visible.height * 0.22
        let y = visible.maxY - size.height - topInset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainThreadIsolation.run {
                self?.handle(keyCode: keyCode) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handle(keyCode: UInt16) -> Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        guard let state else { return false }

        // A confirmation card captures the keyboard: Return confirms, Esc cancels,
        // every other key is swallowed so nothing leaks into the search field.
        if state.isConfirming {
            switch keyCode {
            case 36, 76: confirmPending()
            case 53: state.cancelConfirmation()
            default: break
            }
            return true
        }

        switch keyCode {
        case 125:
            state.moveDown()
            return true
        case 126:
            state.moveUp()
            return true
        case 36, 76:
            if let entry = state.commitSelection() {
                commit(entry)
            }
            return true
        case 48: // Tab: absorb a bare dev-tool keyword into a scope badge.
            if state.isAtRoot {
                state.tryAbsorbDevToolScope()
                return true // swallow Tab either way so focus doesn't jump
            }
            return false
        case 51: // Delete/Backspace: shed the scope badge / pop the second level
            if state.activeDevToolScope != nil, state.query.isEmpty {
                state.removeDevToolScope()
                return true
            }
            if !state.isAtRoot, state.query.isEmpty {
                state.popToRoot()
                return true
            }
            return false // otherwise let the search field delete a character
        case 53: // Esc: clear a non-empty query first, then pop the second level / dismiss
            if state.handleEscape() == .dismiss {
                cancel()
            }
            return true
        default:
            return false
        }
    }

    private func commit(_ entry: PanelEntry) {
        // Option parents drill into a second level instead of closing.
        if case .builtin(let item) = entry.source, CommandPaletteOptions.isOptionParent(item) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let options = await CommandPaletteOptions.options(for: item)
                // Re-check after the await: the window may have resigned key and
                // closed (which nils `state`) during option building.
                guard let state = self.state, self.window?.isVisible == true else { return }
                if let options {
                    // Drill in even when empty (e.g. no listening ports) so the
                    // palette shows its empty state instead of silently closing.
                    state.enterOptions(parentTitle: L(item.titleKey), options)
                } else {
                    self.close() // not an option parent right now (brightness lost its display)
                }
            }
            return
        }

        // A second-level option either confirms (destructive, e.g. a port kill)
        // or runs its action and dismisses.
        if case .paletteOption(let id) = entry.source {
            guard let option = state?.option(id: id) else { close(); return }
            if let confirmation = option.confirmation {
                state?.requestConfirmation(confirmation, perform: option.perform)
            } else {
                close()
                Task { await option.perform() }
            }
            return
        }

        // Killing a port from the root numeric search asks for confirmation too.
        if case .portRecord(let record) = entry.source {
            let confirmation = CommandPaletteOptions.portKillConfirmation(for: record)
            state?.requestConfirmation(confirmation) {
                let result = await PortInventory.shared.kill(pid: record.pid)
                ToastPresenter.shared.show(
                    CommandPalettePortKillToast.style(for: record, result: result)
                )
            }
            return
        }

        // A keyword-completion hint enters its scope and keeps the palette open
        // so the user types the conversion body next — like an option drill-in.
        if case .devToolScopeSuggestion(let scope) = entry.source {
            state?.enterDevToolScope(scope)
            return
        }

        close()
        switch entry.source {
        case .appShortcut(let id):
            guard let binding = PanelStore.shared.binding(id: id) else { return }
            AppSwitcher.toggle(bundleID: binding.appBundleID, appPath: binding.appPath)
        case .installedApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .portRecord:
            break // handled above (routed through confirmation)
        case .builtin(let item):
            switch item.kind {
            case .toggle:
                Task { await PanelStore.shared.toggle(item) }
            case .action:
                Task { await PanelStore.shared.run(item) }
            case .submenu, .brightnessControl, .hiddenHotkey:
                break
            }
        case .calcResult(let result):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.copyText, forType: .string)
            // Suppress clipboard-history capture, matching every other internal
            // copy path (PickColor / OCR / QRCode / Screenshot).
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            ToastPresenter.shared.show(.success(L(.toastCalcCopied, result.display)))
        case .devTool(let result):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.output, forType: .string)
            // Suppress clipboard-history capture, matching every other internal
            // copy path (Calc / PickColor / OCR / QRCode / Screenshot).
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            // Confirm without echoing the value — dev-tool outputs (hashes, multi-line
            // JSON) are long and unhelpful in a toast.
            ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
        case .conversion(let result):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.copyText, forType: .string)
            // Suppress clipboard-history capture, matching every other internal copy path.
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
        case .hostProfile(let id):
            // Toggle the named profile's activation directly (same as the
            // drill-in hosts options — no privileged-write confirmation).
            if let profile = HostsManager.shared.profiles.first(where: { $0.id == id }) {
                Task { await HostsManager.shared.setActive(profile, !profile.isActive) }
            }
        case .devToolScopeSuggestion:
            break // handled above (enters scope, stays open)
        case .paletteOption:
            break // handled above
        }
    }

    /// Run the pending confirmation's action, then dismiss. Reads `perform`
    /// before `close()` (which nils `state` via `windowWillClose`).
    private func confirmPending() {
        guard let perform = state?.pendingConfirmation?.perform else { return }
        close()
        Task { await perform() }
    }

    private func cancel() {
        close()
    }

    /// Force a currency-rates refresh from the footer button and confirm with a
    /// toast. The palette stays open (the toast panel can't become key), so an
    /// updated conversion row re-renders in place.
    private func refreshRates() {
        Task { @MainActor in
            let updated = await CurrencyRatesService.shared.forceRefresh()
            if updated, let date = CurrencyRatesService.shared.rateTable?.date {
                ToastPresenter.shared.show(.success(L(.toastRatesUpdated, date)))
            } else {
                ToastPresenter.shared.show(.failure(L(.toastRatesUpdateFailed)))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        state = nil
    }

    /// Close when focus moves away (Spotlight UX).
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

enum CommandPalettePortKillToast {
    @MainActor
    static func style(for record: PortRecord, result: PortKillResult) -> ToastStyle {
        switch result {
        case .success:
            return .success(L(.toastPortKillSuccess, record.processName, String(record.port)))
        case .failure(.permissionDenied):
            return .failure(L(.toastPortKillPermissionDenied, record.processName))
        case .failure(.processGone):
            return .success(L(.toastPortKillGone, record.processName))
        case .failure(.other(let code)):
            return .failure(L(.toastPortKillFailed, record.processName, String(code)))
        }
    }
}
