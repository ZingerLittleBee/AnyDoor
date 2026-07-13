import AppKit
import SwiftUI

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteWindowController()
    private static let paletteControlKeyCodes: Set<UInt16> = [125, 126, 36, 76, 48, 51, 53]

    private var state: CommandPaletteState?
    private let activationGate = CommandPaletteActivationGate()
    private let searchCoordinator = CommandPaletteSearchField.Coordinator()
    private var searchField: NSTextField?
    private weak var searchAnchor: CommandPaletteSearchAnchorView?
    private var keyMonitor: Any?
    private var isClosing = false
    /// Last installed-apps scan, refreshed off the main actor on every open. Seeds
    /// the Applications section instantly so summoning the palette never blocks on
    /// a fresh `/Applications` walk; empty only before the very first scan returns.
    private var cachedApps: [InstalledApp] = []

    static func makePanel() -> NSPanel {
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
        panel.isMovableByWindowBackground = false
        // A fully clear NSPanel loses the active NSTextField's I-beam cursor on
        // macOS 26. A visually imperceptible alpha keeps AppKit's cursor rects
        // intact without changing the transparent rounded-window appearance.
        panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.001)
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        return panel
    }

    static func makeContentContainer(
        for window: NSWindow,
        hostingView: NSView,
        searchField: NSView
    ) -> NSView {
        let fullContentBounds = window.contentView?.bounds
            ?? NSRect(origin: .zero, size: window.frame.size)
        let contentView = NSView(frame: fullContentBounds)
        hostingView.frame = contentView.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostingView)
        contentView.addSubview(searchField, positioned: .above, relativeTo: hostingView)
        return contentView
    }

    private init() {
        let panel = Self.makePanel()
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Toggle visibility: hide if already showing, otherwise show fresh.
    func toggle() {
        if window?.isVisible == true || activationGate.isWaiting {
            close()
        } else {
            show()
        }
    }

    func showArgumentInput(quicklinkID: UUID, title: String, link: String, openWithBundleID: String?) {
        show(initialMode: .argumentInput(
            quicklinkID: quicklinkID,
            title: title,
            link: link,
            openWithBundleID: openWithBundleID
        ))
    }

    private enum InitialMode {
        case root
        case argumentInput(quicklinkID: UUID, title: String, link: String, openWithBundleID: String?)

        @MainActor
        func apply(to state: CommandPaletteState) {
            switch self {
            case .root:
                break
            case .argumentInput(let quicklinkID, let title, let link, let openWithBundleID):
                state.enterArgumentInput(
                    quicklinkID: quicklinkID,
                    title: title,
                    link: link,
                    openWithBundleID: openWithBundleID
                )
            }
        }
    }

    private func show(initialMode: InitialMode = .root) {
        guard let window else { return }
        activationGate.cancel()
        removeKeyMonitor()
        searchCoordinator.onChange = { _ in }
        searchAnchor?.onLayout = nil
        searchField = nil
        searchAnchor = nil

        let sections = collectSections(installedApps: cachedApps)
        prewarmIcons(for: sections)
        let hyperFlags = HyperKeyService.shared.hyperModifierFlags
        let pickerState = CommandPaletteState(
            sections: sections,
            hyperFlags: hyperFlags,
            quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates()
        )
        initialMode.apply(to: pickerState)
        self.state = pickerState
        searchCoordinator.onChange = { [weak pickerState] text in
            guard let pickerState, pickerState.query != text else { return }
            pickerState.query = text
        }
        let searchField = CommandPaletteSearchField.make(coordinator: searchCoordinator)
        self.searchField = searchField

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
            },
            registerSearchAnchor: { [weak self] anchor, text, placeholder in
                self?.registerSearchAnchor(anchor, text: text, placeholder: placeholder)
            }
        )

        let host = NSHostingView(rootView: view)
        let contentView = Self.makeContentContainer(
            for: window,
            hostingView: host,
            searchField: searchField
        )
        window.contentView = contentView
        host.layoutSubtreeIfNeeded()
        layoutSearchField()

        positionAtTopCenter()
        activationGate.presentWhenActive(prepareForActivation: { [weak self, weak pickerState] in
            guard let self, let pickerState, self.state === pickerState else { return }
            self.window?.orderFrontRegardless()
        }) { [weak self, weak pickerState] in
            guard let self, let pickerState, self.state === pickerState else { return }
            self.installKeyMonitor()
            self.window?.makeKeyAndOrderFront(nil)
            self.focusSearchField()
            self.refreshSections(for: pickerState)
        }
    }

    private func refreshSections(for pickerState: CommandPaletteState) {
        // After the window is on screen, refresh state that the synchronous
        // seed above can't supply, then repopulate the sections in place (the
        // @Observable state re-renders). Two pieces, folded into one task so the
        // section rebuild happens exactly once:
        //   1. Toggle states. `topLevelEntries.toggleState` is only accurate
        //      after `PanelStore.refreshAll()` polls each provider, which today
        //      runs from the menu-bar panel's onAppear. Without this, a palette
        //      opened before the panel shows every toggle as off, so the on-state
        //      icon styling never appears.
        //   2. The installed-apps list, scanned OFF the main actor so the
        //      `/Applications` walk never delays summoning the palette.
        Task { [weak self, weak pickerState] in
            await PanelStore.shared.refreshAll()
            let apps = await Task.detached(priority: .userInitiated) {
                InstalledAppsScanner.scan()
            }.value
            guard let self else { return }
            self.cachedApps = apps
            guard let pickerState, self.state === pickerState, self.window?.isVisible == true else { return }
            let refreshed = self.collectSections(installedApps: apps)
            pickerState.updateSections(
                refreshed,
                quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates()
            )
            self.prewarmIcons(for: refreshed)
        }
    }

    private func registerSearchAnchor(
        _ anchor: CommandPaletteSearchAnchorView,
        text: String,
        placeholder: String
    ) {
        searchAnchor = anchor
        guard let searchField else { return }
        searchField.placeholderString = placeholder
        if searchField.stringValue != text {
            searchField.stringValue = text
            if let editor = searchField.currentEditor() as? NSTextView {
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            }
        }
        layoutSearchField()
    }

    private func layoutSearchField() {
        guard let window, let contentView = window.contentView,
              let searchAnchor, let searchField, searchAnchor.window === window
        else { return }
        let frame = searchAnchor.convert(searchAnchor.bounds, to: contentView)
        guard frame.width > 0, frame.height > 0 else { return }
        guard searchField.frame != frame else { return }
        searchField.frame = frame
    }

    private func focusSearchField() {
        guard let window, window.isKeyWindow, let searchField else { return }
        guard window.makeFirstResponder(searchField) else { return }
        let end = (searchField.stringValue as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// Warm the icon cache for every app-backed row off the main thread, so the
    /// first scroll into the Applications section finds resolved icons instead of
    /// cold-cache disk hits. Mirrors CommandPaletteRow.iconPath.
    private func prewarmIcons(for sections: [CommandPaletteSection]) {
        let entries = sections.flatMap(\.entries)
        AppIconCache.prewarm(entries.compactMap { entry in
            switch entry.source {
            case .installedApp(_, let path): return path
            case .appShortcut(let id): return PanelStore.shared.binding(id: id)?.appPath
            case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .hostProfile, .quicklink, .quicklinkTemplate, .quicklinkArgument:
                return nil
            }
        })
        QuicklinkIconProvider.prewarm(entries.compactMap(\.quicklinkIcon))
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
        // Carve themed sub-groups out of the flat command list. Any command not
        // claimed by a group falls back to the general Commands section, which
        // is listed first; the groups follow in declaration order.
        func builtin(_ entry: PanelEntry) -> BuiltinItem? {
            if case .builtin(let item) = entry.source { return item }
            return nil
        }
        // Source the themed sub-groups from the shared BuiltinGroup catalog so
        // the palette and the Panel settings page never drift. Order and titles
        // are unchanged: themedDefaultOrder is [toggles, power, capture, translation].
        let groups: [(L10n.Key, Set<BuiltinItem>)] = BuiltinGroup.themedDefaultOrder.map { group in
            (group.titleKey!, group.members)
        }
        let grouped = groups.reduce(into: Set<BuiltinItem>()) { $0.formUnion($1.1) }
        let generalCommands = commands.filter { entry in
            guard let item = builtin(entry) else { return true }
            return !grouped.contains(item)
        }
        let quicklinks = QuicklinkStore.shared.paletteEntries()
        let generalEntries = generalCommands + quicklinks
        if !generalEntries.isEmpty {
            sections.append(CommandPaletteSection(
                titleKey: .commandPaletteSectionCommands,
                entries: generalEntries
            ))
        }
        for (titleKey, items) in groups {
            let entries = commands.filter { builtin($0).map(items.contains) ?? false }
            guard !entries.isEmpty else { continue }
            sections.append(CommandPaletteSection(titleKey: titleKey, entries: entries))
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

        guard Self.paletteControlKeyCodes.contains(keyCode) else { return false }

        // While the input method is composing (marked text — e.g. typing
        // Chinese pinyin), every key belongs to the IME: Return commits the
        // composition, arrows navigate candidates, Esc cancels it. Pass the
        // event through so the field editor handles it instead of the palette.
        if window.hasIMEComposition { return false }

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
        case 48: // Tab: absorb a bare keyword into a badge (dev-tool scope, else Quicklink argument).
            if state.isAtRoot {
                if !state.tryAbsorbDevToolScope() {
                    state.tryAbsorbQuicklinkKeyword()
                }
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
        switch CommandPaletteCommitIntent.classify(entry.source) {
        case .drillIntoOptions(let item):
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
        case .runOrConfirmOption(let id):
            guard let option = state?.option(id: id) else { close(); return }
            if let confirmation = option.confirmation {
                state?.requestConfirmation(confirmation, perform: option.perform)
            } else {
                close()
                Task { await option.perform() }
            }
        case .confirmPortKill(let record):
            let confirmation = CommandPaletteOptions.portKillConfirmation(for: record)
            state?.requestConfirmation(confirmation) {
                let result = await PortInventory.shared.kill(pid: record.pid)
                ToastPresenter.shared.show(
                    CommandPalettePortKillToast.style(for: record, result: result)
                )
            }
        case .enterDevToolScope(let scope):
            state?.enterDevToolScope(scope)
        case .enterQuicklinkArgument(let id):
            guard let quicklink = QuicklinkStore.shared.quicklink(id: id) else { close(); return }
            state?.enterArgumentInput(
                quicklinkID: id,
                title: quicklink.displayName,
                link: quicklink.link,
                openWithBundleID: quicklink.openWithBundleID,
                keyword: quicklink.keyword
            )
        case .launchAppShortcut(let id):
            close()
            guard let binding = PanelStore.shared.binding(id: id) else { return }
            AppSwitcher.toggle(bundleID: binding.appBundleID, appPath: binding.appPath)
        case .launchApp(let bundleID, let path):
            close()
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .toggleBuiltin(let item):
            close()
            Task { await PanelStore.shared.toggle(item) }
        case .runBuiltin(let item):
            close()
            Task { await PanelStore.shared.run(item) }
        case .copyToClipboard(let text, let toast):
            close()
            ClipboardWatcher.selfWrite(string: text)
            switch toast {
            case .calc(let display):
                ToastPresenter.shared.show(.success(L(.toastCalcCopied, display)))
            case .generic:
                ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
            }
        case .toggleHostProfile(let id):
            close()
            // Toggle the named profile's activation directly (same as the
            // drill-in hosts options — no privileged-write confirmation).
            if let profile = HostsManager.shared.profiles.first(where: { $0.id == id }) {
                Task { await HostsManager.shared.setActive(profile, !profile.isActive) }
            }
        case .openQuicklink(let id):
            close()
            guard let quicklink = QuicklinkStore.shared.quicklink(id: id) else { return }
            QuicklinkOpener.shared.open(quicklink)
        case .openQuicklinkArgument(let id, let argument):
            close()
            guard let quicklink = QuicklinkStore.shared.quicklink(id: id) else { return }
            QuicklinkOpener.shared.open(quicklink, argument: argument)
        case .dismiss:
            close()
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

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        resetPresentation()
        super.close()
        isClosing = false
    }

    private func resetPresentation() {
        activationGate.cancel()
        removeKeyMonitor()
        searchCoordinator.onChange = { _ in }
        searchAnchor?.onLayout = nil
        searchField = nil
        searchAnchor = nil
        state = nil
    }

    func windowWillClose(_ notification: Notification) {
        resetPresentation()
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
