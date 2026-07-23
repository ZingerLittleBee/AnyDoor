import AppKit
import SwiftUI
import PluginInterface
import PluginSupport
import ScriptPluginRuntime

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CommandPaletteWindowController()
    private static let paletteControlKeyCodes: Set<UInt16> = [125, 126, 36, 76, 48, 51, 53]

    private var state: CommandPaletteState?
    private let activationGate = CommandPaletteActivationGate()
    private let windowPlacement = CommandPaletteWindowPlacement()
    private let searchCoordinator = CommandPaletteSearchField.Coordinator()
    private var searchField: NSTextField?
    private weak var searchAnchor: CommandPaletteSearchAnchorView?
    private var keyMonitor: Any?
    private var isClosing = false
    /// State retained across a close while the user sat on a plugin surface (a
    /// pushed list or Detail), so the next plain open resumes there — hiding
    /// the palette mid-read must not reset a v2ex post back to the root.
    /// Validated against the live row-source registrations before reuse.
    private var retainedState: CommandPaletteState?
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

    /// Recompose a visible palette after the installed plugin set changes.
    /// Root queries stay in place, while drill-in state is discarded because
    /// it may hold option closures from a plugin that just uninstalled.
    func refreshPluginSurfaces() {
        guard let state, window?.isVisible == true else { return }
        if !state.isAtRoot {
            state.popToRoot()
        }
        let sections = collectSections(installedApps: cachedApps)
        state.updateSections(
            sections,
            quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates(),
            pluginRowSources: CommandPaletteExtensions.shared.rowSources
        )
        state.selectedIndex = 0
        prewarmIcons(for: sections)
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
        let pickerState: CommandPaletteState
        var resumeRepair: CommandPaletteState.ResumeRepair?
        if case .root = initialMode, let resumed = takeRetainedState() {
            // Resume the plugin surface the user was on when the palette closed.
            // Root sections and row-source registrations are refreshed in place;
            // the drill-in stack (list rows, Detail content) is kept as-is.
            pickerState = resumed
            pickerState.updateSections(
                sections,
                quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates(),
                pluginRowSources: CommandPaletteExtensions.shared.rowSources
            )
            resumeRepair = pickerState.prepareForResume()
        } else {
            retainedState = nil
            pickerState = CommandPaletteState(
                sections: sections,
                hyperFlags: HyperKeyService.shared.hyperModifierFlags,
                quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates()
            )
            initialMode.apply(to: pickerState)
        }
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
            onOpenDetailLink: { [weak self] url in
                self?.openDetailLink(url)
            },
            onLoadDetailMore: { [weak self] in
                self?.loadMoreDetail()
            },
            onLoadListMore: { [weak self] in
                self?.loadMoreList()
            },
            onDetailAction: { [weak self] actionID in
                self?.performDetailAction(actionID: actionID)
            },
            onRetryDetail: { [weak self] in
                self?.retryDetail()
            },
            onRetryList: { [weak self] in
                self?.retryList()
            },
            onDetailActiveChange: { [weak self] inDetail in
                self?.setSearchFieldActive(!inDetail)
            },
            onLevelChange: { [weak self] in
                self?.relayoutSearchFieldSoon()
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

        restorePosition()
        activationGate.presentWhenActive(prepareForActivation: { [weak self, weak pickerState] in
            guard let self, let pickerState, self.state === pickerState else { return }
            self.window?.orderFrontRegardless()
        }) { [weak self, weak pickerState] in
            guard let self, let pickerState, self.state === pickerState else { return }
            self.installKeyMonitor()
            self.window?.makeKeyAndOrderFront(nil)
            if pickerState.isInDetail {
                // Resumed straight into a Detail: `onDetailActiveChange` only
                // fires on a change, so hide the overlaid field explicitly.
                self.setSearchFieldActive(false)
            } else {
                self.focusSearchField()
            }
            self.refreshSections(for: pickerState)
            if let resumeRepair {
                self.performResumeRepair(resumeRepair)
            }
        }
    }

    /// The retained navigation to resume, if it is still presentable — every
    /// row source it references must remain registered (a plugin uninstalled
    /// while the palette was hidden invalidates it). Consumes the slot either
    /// way, so a discarded navigation cannot resurface on a later open.
    private func takeRetainedState() -> CommandPaletteState? {
        defer { retainedState = nil }
        guard let retained = retainedState,
              retained.canResume(sourceExists: { CommandPaletteExtensions.shared.rowSource(for: $0) != nil })
        else { return nil }
        return retained
    }

    /// Re-kick the fetch a resumed level lost to the close (its pre-close task
    /// dropped the result behind the visibility guard, so the level would show
    /// its loading placeholder forever).
    private func performResumeRepair(_ repair: CommandPaletteState.ResumeRepair) {
        switch repair {
        case .reloadDetail(let sourceKey, let rowID, let title, let generation):
            resolveDetail(sourceKey: sourceKey, rowID: rowID, title: title, generation: generation)
        case .reloadList(let sourceKey, let listID, let generation):
            resolveList(sourceKey: sourceKey, listID: listID, generation: generation)
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
                quicklinkTemplateCandidates: QuicklinkStore.shared.templateCandidates(),
                pluginRowSources: CommandPaletteExtensions.shared.rowSources
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

    /// Re-anchor the overlaid AppKit search field one runloop after a navigation
    /// transition. A second level inserts a back-header row that shifts the
    /// field's SwiftUI slot down; returning to the root removes it. The SwiftUI
    /// anchor's own `layout()` fires only when its own size changes, not when an
    /// ancestor moves it, so `registerSearchAnchor` alone leaves the field one
    /// transition behind. Deferring a runloop lets SwiftUI finish its layout pass
    /// so the anchor reports its new frame, mirroring `setSearchFieldActive`.
    /// A hidden field (Detail) is repositioned harmlessly and stays hidden.
    private func relayoutSearchFieldSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.layoutSearchField()
        }
    }

    private func focusSearchField() {
        guard let window, window.isKeyWindow, let searchField else { return }
        guard window.makeFirstResponder(searchField) else { return }
        let end = (searchField.stringValue as NSString).length
        searchField.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// Show or hide the overlaid AppKit search field around the Detail level.
    /// Detail has no text input, so its field is hidden and first responder is
    /// dropped (no stray caret); returning to a searchable level re-shows and
    /// refocuses it once SwiftUI has re-registered the anchor.
    private func setSearchFieldActive(_ active: Bool) {
        guard let searchField else { return }
        if active {
            searchField.isHidden = false
            // Defer a runloop so the re-rendered SwiftUI anchor has registered
            // its frame before we position and focus the field.
            DispatchQueue.main.async { [weak self] in
                self?.layoutSearchField()
                self?.focusSearchField()
            }
        } else {
            window?.makeFirstResponder(window)
            searchField.isHidden = true
        }
    }

    /// Open a markdown link tapped inside the Detail pane. The URL is
    /// plugin-supplied, so it is confined to the `openURL` scheme allowlist
    /// (ADR-0009) before opening; either way the palette dismisses, mirroring a
    /// Row Action `openURL` commit.
    private func openDetailLink(_ url: URL) {
        guard ScriptOpenURLPolicy.allows(url) else {
            close()
            ToastPresenter.shared.show(.failure(L(.pluginsActionFailed)))
            return
        }
        close()
        NSWorkspace.shared.open(url)
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
            case .builtin, .portRecord, .calcResult, .devTool, .devToolScopeSuggestion, .conversion, .paletteOption, .pluginRow, .quicklink, .quicklinkTemplate, .quicklinkArgument:
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

        // Give every plugin row source one refresh at palette open (e.g. hosts
        // profiles re-fetch) so the root name-search sections reflect current
        // data without a per-keystroke fetch.
        for registration in CommandPaletteExtensions.shared.rowSources {
            registration.source.reload()
        }

        // Kick a currency-rates refresh (at most once per day) so inline currency
        // conversion has a fresh table. Fire-and-forget; the cached table is used
        // immediately and updated rows appear as the user keeps typing.
        Task { await CurrencyRatesService.shared.refreshIfStale() }

        let commands = store.topLevelEntries.filter { entry in
            guard entry.isVisible else { return false }
            guard case .builtin(let item) = entry.source else { return false }
            switch item.kind {
            case .toggle, .action:
                return true
            case .brightnessControl, .submenu:
                // Only the option parents the palette drills into; App Shortcuts
                // and Window Layout keep their own flat sections. Brightness
                // registers a DDC-gated listing policy.
                return CommandPaletteExtensions.shared.listsAtRoot(item)
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
                PanelEntry.paletteRow(
                    source: .installedApp(bundleID: app.bundleID, path: app.path),
                    displayOrder: unboundOrder + Double(offset),
                    title: app.displayName,
                    symbol: "app.fill",
                    kind: .submenu
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

    private func restorePosition() {
        guard let window else { return }
        let screens = NSScreen.screens
        let windowSize = window.frame.size

        if let restoredFrame = windowPlacement.restoredFrame(
            windowSize: windowSize,
            visibleFrames: screens.map(\.visibleFrame)
        ), let screen = screens.first(where: { $0.visibleFrame.intersects(restoredFrame) }) {
            let constrainedFrame = window.constrainFrameRect(restoredFrame, to: screen)
            window.setFrame(constrainedFrame, display: false)
            return
        }

        guard let visibleFrame = NSScreen.main?.visibleFrame else { return }
        let defaultFrame = CommandPaletteWindowPlacement.defaultFrame(
            windowSize: windowSize,
            visibleFrame: visibleFrame
        )
        window.setFrame(defaultFrame, display: false)
    }

    private func savePosition() {
        guard let window, window.isVisible else { return }
        windowPlacement.save(origin: window.frame.origin)
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
            // A failed drill-in maps Return to retry: a Detail has no rows to
            // commit, and a failed list's only row is the error placeholder.
            if state.detailRetryAvailable {
                retryDetail()
                return true
            }
            if state.listRetryAvailable {
                retryList()
                return true
            }
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
                state.popLevel()
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
                let options = await CommandPaletteExtensions.shared.options(for: item)
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
        case .pluginRowStayOpen(let sourceKey, let rowID):
            guard let source = CommandPaletteExtensions.shared.rowSource(for: sourceKey) else { return }
            Task { await source.performRow(id: rowID) }
        case .pluginRowCloseThenAct(let sourceKey, let rowID):
            close()
            guard let source = CommandPaletteExtensions.shared.rowSource(for: sourceKey) else { return }
            Task { await source.performRow(id: rowID) }
        case .pluginRowPushDetail(let sourceKey, let rowID, let title):
            pushPluginDetail(sourceKey: sourceKey, rowID: rowID, title: title)
        case .pluginRowPushList(let sourceKey, let listID, let title):
            pushPluginList(sourceKey: sourceKey, listID: listID, title: title)
        case .pluginRowEnterArgument(let sourceKey, let rowID, let title):
            state?.enterPluginArgumentInput(sourceKey: sourceKey, rowID: rowID, title: title)
        case .pluginRowRunArgument(let sourceKey, let rowID, let argument):
            close()
            guard let source = CommandPaletteExtensions.shared.rowSource(for: sourceKey) else { return }
            Task { await source.performRow(id: rowID, argument: argument) }
        case .noAction:
            // A loading placeholder / inline error row: keep the palette open.
            break
        case .openURL(let url):
            close()
            guard let parsed = URL(string: url) else { return }
            NSWorkspace.shared.open(parsed)
        case .openURLRejected:
            close()
            ToastPresenter.shared.show(.failure(L(.pluginsActionFailed)))
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

    /// Push a plugin row's markdown Detail: show the loading level immediately,
    /// then resolve the markdown off the row source and update in place. Guards
    /// re-check that the same Detail is still visible after the await, so a
    /// dismissed palette or a mid-flight uninstall can neither hang nor resurface.
    private func pushPluginDetail(sourceKey: PluginRowSourceKey, rowID: String, title: String) {
        guard let generation = state?.enterDetail(sourceKey: sourceKey, rowID: rowID, title: title) else { return }
        resolveDetail(sourceKey: sourceKey, rowID: rowID, title: title, generation: generation)
    }

    /// Fetch a Detail's initial document and land it under `generation`. Shared
    /// by the drill-in push and the resume repair (a Detail that closed while
    /// still loading re-requests through here).
    private func resolveDetail(sourceKey: PluginRowSourceKey, rowID: String, title: String, generation: Int) {
        guard let source = CommandPaletteExtensions.shared.rowSource(for: sourceKey) else {
            state?.updateDetail(.failed(title: title, message: L(.commandPaletteDetailFailed)), generation: generation)
            return
        }
        Task { @MainActor [weak self] in
            let result = await source.loadDetail(id: rowID, cursor: nil)
            // The generation token ensures a slow result only lands on the exact
            // drill-in that requested it — never on a later Detail (A→back→B).
            guard let self, let state = self.state, self.window?.isVisible == true else { return }
            switch result {
            case .markdown(let markdown, let more, let actions):
                state.updateDetail(
                    .loaded(title: title, markdown: markdown),
                    more: more, actions: actions, generation: generation)
            case .failure(let message):
                state.updateDetail(.failed(title: title, message: message), generation: generation)
            case nil:
                state.updateDetail(.failed(title: title, message: L(.commandPaletteDetailFailed)), generation: generation)
            }
        }
    }

    /// Run a Detail footer action: the document drops to its loading state and
    /// the action's result replaces it wholesale (its own markdown, cursor, and
    /// actions). Same guards as the initial load — the generation token keys
    /// the result to this exact drill-in, and `beginDetailAction` refuses a
    /// second press while a rebuild is in flight.
    private func performDetailAction(actionID: String) {
        guard let state, let request = state.beginDetailAction() else { return }
        let title = state.detailState?.title ?? ""
        guard let source = CommandPaletteExtensions.shared.rowSource(for: request.sourceKey) else {
            state.updateDetail(.failed(title: title, message: L(.commandPaletteDetailFailed)), generation: request.generation)
            return
        }
        Task { @MainActor [weak self] in
            let result = await source.loadDetailAction(id: request.rowID, actionID: actionID)
            guard let self, let state = self.state, self.window?.isVisible == true else { return }
            switch result {
            case .markdown(let markdown, let more, let actions):
                state.updateDetail(
                    .loaded(title: title, markdown: markdown),
                    more: more, actions: actions, generation: request.generation)
            case .failure(let message):
                state.updateDetail(.failed(title: title, message: message), generation: request.generation)
            case nil:
                state.updateDetail(.failed(title: title, message: L(.commandPaletteDetailFailed)), generation: request.generation)
            }
        }
    }

    /// Re-request a failed Detail's document in place (the error state's retry
    /// button, or Return while it shows). The state claim flips the level back
    /// to loading and refuses anything but a failed Detail; the shared
    /// `resolveDetail` lands the result under the same navigation generation.
    private func retryDetail() {
        guard let request = state?.retryDetail() else { return }
        resolveDetail(
            sourceKey: request.sourceKey, rowID: request.rowID,
            title: request.title, generation: request.generation)
    }

    /// Fetch the next Detail chunk when the user scrolls to the bottom sentinel.
    /// The state's `beginDetailMore` is the single gate (loaded Detail + cursor +
    /// no fetch in flight), so a sentinel that fires repeatedly cannot stack
    /// requests; the generation token keys the append to this exact drill-in.
    private func loadMoreDetail() {
        guard let state, let request = state.beginDetailMore() else { return }
        guard let source = CommandPaletteExtensions.shared.rowSource(for: request.sourceKey) else {
            state.failDetailMore(generation: request.generation, document: request.document)
            return
        }
        Task { @MainActor [weak self] in
            let result = await source.loadDetail(id: request.rowID, cursor: request.cursor)
            guard let self, let state = self.state, self.window?.isVisible == true else { return }
            switch result {
            case .markdown(let markdown, let more, _):
                // An appended chunk's actions are ignored: the footer bar
                // belongs to the full document, not to a page of it.
                state.appendDetailChunk(
                    markdown, more: more,
                    generation: request.generation, document: request.document)
            case .failure, nil:
                // Keep what is already rendered; stop paginating quietly.
                state.failDetailMore(generation: request.generation, document: request.document)
            }
        }
    }

    /// Push a plugin row's searchable second-level list: show the loading level
    /// immediately, then build the rows off the row source and update in place.
    /// Guards re-check that the same list is still visible after the await, so a
    /// dismissed palette or a mid-flight uninstall can neither hang nor resurface;
    /// the generation token keys a slow result to the exact drill-in that asked
    /// for it (list A -> back -> list B). Mirrors `pushPluginDetail`.
    private func pushPluginList(sourceKey: PluginRowSourceKey, listID: String, title: String) {
        let generation = state?.enterList(sourceKey: sourceKey, listID: listID, title: title)
        guard let generation else { return }
        resolveList(sourceKey: sourceKey, listID: listID, generation: generation)
    }

    /// Build a pushed list's rows and land them under `generation`. Shared by
    /// the drill-in push and the resume repair, mirroring `resolveDetail`.
    private func resolveList(sourceKey: PluginRowSourceKey, listID: String, generation: Int) {
        guard let source = CommandPaletteExtensions.shared.rowSource(for: sourceKey) else {
            state?.updateList(.failed(L(.commandPalettePluginRowError)), generation: generation)
            return
        }
        Task { @MainActor [weak self] in
            let result = await source.loadList(id: listID, query: "", cursor: nil)
            guard let self, let state = self.state, self.window?.isVisible == true else { return }
            switch result {
            case .rows(let rows, let more):
                state.updateList(.loaded(rows), more: more, generation: generation)
            case .failure(let message):
                state.updateList(.failed(message), generation: generation)
            case nil:
                state.updateList(.failed(L(.commandPalettePluginRowError)), generation: generation)
            }
        }
    }

    /// Re-request a failed pushed list's rows in place. Mirrors `retryDetail`.
    private func retryList() {
        guard let request = state?.retryList() else { return }
        resolveList(
            sourceKey: request.sourceKey, listID: request.listID,
            generation: request.generation)
    }

    /// Fetch the next list page when the user scrolls to the bottom sentinel.
    /// The state's `beginListMore` is the single gate (loaded list + cursor +
    /// no fetch in flight), so a sentinel that fires repeatedly cannot stack
    /// requests; the generation token keys the append to this exact drill-in.
    /// Mirrors `loadMoreDetail`.
    private func loadMoreList() {
        guard let state, let request = state.beginListMore() else { return }
        guard let source = CommandPaletteExtensions.shared.rowSource(for: request.sourceKey) else {
            state.failListMore(generation: request.generation)
            return
        }
        Task { @MainActor [weak self] in
            let result = await source.loadList(
                id: request.listID, query: "", cursor: request.cursor)
            guard let self, let state = self.state, self.window?.isVisible == true else { return }
            switch result {
            case .rows(let rows, let more):
                state.appendListRows(rows, more: more, generation: request.generation)
            case .failure, nil:
                // Keep what is already shown; stop paginating quietly.
                state.failListMore(generation: request.generation)
            }
        }
    }

    /// Recompute a visible palette's rows in place after an async plugin row
    /// source finishes loading — no popToRoot, so a drilled-in Detail survives.
    func refreshVisibleRows() {
        guard let state, window?.isVisible == true else { return }
        state.notePluginRowsChanged()
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
        savePosition()
        resetPresentation()
        super.close()
        isClosing = false
    }

    private func resetPresentation() {
        // Retain the state when the user was on a plugin surface so the next
        // open resumes there; any other level (root, options, argument input)
        // resets as before. A nil state (already-reset re-entry from
        // `windowWillClose`) leaves the retained slot untouched.
        if let state {
            retainedState = state.isResumablePluginSurface ? state : nil
        }
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

    func windowDidMove(_ notification: Notification) {
        savePosition()
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
