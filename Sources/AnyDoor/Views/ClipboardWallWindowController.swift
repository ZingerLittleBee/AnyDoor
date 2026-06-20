import AppKit
import QuartzCore
import QuickLookUI
import SwiftData
import SwiftUI

/// Bottom, full-width overlay that hosts the clipboard card wall. Summoned by
/// the clipboard-wall hotkey (via ClipboardWallProvider) or the panel row.
/// Mirrors CommandPaletteWindowController's activation/key-monitor pattern.
@MainActor
final class ClipboardWallWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource {
    static let shared = ClipboardWallWindowController()

    /// Set by AppDelegate so paste-from-history can suppress the self-write.
    weak var watcher: ClipboardWatcher?
    /// The shared SwiftData container, injected by AppDelegate. Needed so the
    /// wall's @Query observes the same context the watcher writes to.
    var modelContainer: ModelContainer?

    private let state = ClipboardWallState()
    /// Rebuilt fresh on every show. Reusing it across opens breaks SwiftUI
    /// reactivity — a reused host that was ordered out does not re-subscribe to
    /// its @Query/@Observable sources, so new captures only appeared after a tab
    /// switch forced a body re-evaluation. A LazyHStack keeps the rebuild cheap.
    private var hostingView: NSHostingView<AnyView>?
    /// The wall's search field, published by `WallSearchField`. Held so the key
    /// monitor can make it first responder synchronously for type-to-focus.
    private weak var searchField: NSTextField?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var flagsMonitor: Any?
    private var globalMouseMonitor: Any?
    /// Accumulated scroll delta; selection advances each time it crosses a step.
    private var scrollAccum: CGFloat = 0
    private static let scrollStep: CGFloat = 40
    /// Height of the wall's top strip (14pt top padding + tab/search row) where
    /// scrolls belong to the tab row's own horizontal ScrollView, not card
    /// navigation. Keep in sync with ClipboardWallView's layout.
    private static let topStripHeight: CGFloat = 48
    private var previewURL: URL?

    /// The app that was frontmost when the wall opened. The wall activates
    /// AnyDoor so its panel can become key (a background .accessory app's panel
    /// won't otherwise receive keyboard events); focus is returned here on
    /// paste/Esc so the net effect is no focus theft.
    private weak var previousApp: NSRunningApplication?

    /// Guards against re-entrant show/dismiss while the slide animation runs.
    private var isAnimating = false
    private static let panelHeight: CGFloat = 285
    private static let animationDuration: TimeInterval = 0.22

    private var historyDirectory: URL { ClipboardHistoryStore.defaultHistoryDirectory() }

    private init() {
        let panel = ClipboardWallPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Become key as soon as shown so keyboard nav / search work without
        // waiting for a control to demand it.
        panel.becomesKeyOnlyIfNeeded = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        guard !isAnimating else { return }
        // The wall hotkey while the editor is up steps the editor down first
        // (dirty-checked) instead of silently tearing the whole stack down.
        if ClipboardTextWindow.shared.isEditing {
            ClipboardTextWindow.shared.requestClose()
            return
        }
        if window?.isVisible == true { dismiss(restoreFocus: true) } else { show() }
    }

    private func show() {
        // Always open on "All" with no search so a freshly copied item (of any
        // kind) is guaranteed to be visible rather than hidden behind a leftover
        // category tab or search term.
        state.category = .all
        state.query = ""
        // Open in card-navigation mode (search field unfocused); typing focuses
        // it. Reset here so a prior session's focus state never leaks in.
        state.isSearchFocused = false
        // Never resurface a stale tag dialog (it may pin a deleted item).
        state.tagDialog = nil
        state.tagDialogText = ""
        // Seed from the live flags: ⌥ may already be held when the wall opens,
        // and the monitor only reports subsequent changes.
        state.isReorderModifierHeld = NSEvent.modifierFlags.contains(.option)
        // Force the watcher to capture immediately so content copied just before
        // opening shows up now, rather than after the next ~0.5s poll tick. The
        // @Query-backed view re-renders on its own once the store changes.
        Task { [weak self] in await self?.watcher?.poll() }
        installHostingView()
        installMonitors()
        // Preview → editor handoff ("e" key / the preview header's edit
        // button) goes down the same path as the card's context menu.
        ClipboardTextWindow.shared.onEditRequest = { [weak self] item in self?.beginEdit(item) }

        guard let window, let screen = NSScreen.main else { return }
        // Remember who had focus so paste/Esc can hand it back.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != NSRunningApplication.current.processIdentifier {
            previousApp = front
        }
        // Anchor to the screen's physical bottom edge (not visibleFrame, which
        // sits above the Dock) so the panel is flush with no gap underneath.
        let bounds = screen.frame
        let onScreen = NSRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width, height: Self.panelHeight)
        // Lay the content out at its final size now, off-screen, so any pending
        // render work happens before the slide rather than stuttering it.
        hostingView?.frame = NSRect(origin: .zero, size: onScreen.size)
        hostingView?.layoutSubtreeIfNeeded()
        window.setFrame(onScreen.offsetBy(dx: 0, dy: -Self.panelHeight), display: false)
        // Make the panel key WITHOUT activating AnyDoor: ClipboardWallPanel
        // overrides canBecomeKey, and the .nonactivatingPanel style keeps the
        // previously active app active, so it doesn't visibly lose focus while
        // the wall is up (Paste-style). Keyboard nav and search still work.
        window.makeKeyAndOrderFront(nil)
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            MainThreadIsolation.run { self?.isAnimating = false }
        })

        // Enforce retention off the critical path; the @Query view reflects any
        // resulting deletions automatically.
        Task { await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false) }
    }

    /// Slide the panel down off-screen, then close it. When `restoreFocus` is
    /// true the previously frontmost app is reactivated first (Esc / paste);
    /// for a click elsewhere it is false, since that click already moved focus.
    /// `completion` runs after the window has ordered out, so paste can post ⌘V
    /// once focus has returned. No-op if already hidden or mid-animation.
    private func dismiss(restoreFocus: Bool, completion: (@Sendable () -> Void)? = nil) {
        // The floating text panel has no life of its own once the wall goes away.
        ClipboardTextWindow.shared.close()
        guard !isAnimating, let window, window.isVisible, let screen = NSScreen.main else {
            completion?()
            return
        }
        if restoreFocus { previousApp?.activate() }
        let bounds = screen.frame
        let height = window.frame.height
        let offScreen = NSRect(x: bounds.minX, y: bounds.minY - height,
                               width: window.frame.width, height: height)
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().setFrame(offScreen, display: true)
        }, completionHandler: { [weak self] in
            MainThreadIsolation.run {
                self?.isAnimating = false
                self?.close()
                completion?()
            }
        })
    }

    /// The wall content, with the shared SwiftData container injected so its
    /// @Query observes the same context the watcher writes to. Wrapped in AnyView
    /// because `.modelContainer` changes the concrete view type.
    private func makeWallView() -> AnyView {
        let view = ClipboardWallView(
            state: state,
            historyDirectory: historyDirectory,
            onSelect: { [weak self] item, plain in self?.paste(item, plain: plain) },
            onToggleFavorite: { item in
                Task { await ClipboardHistoryStore.shared.toggleFavorite(item) }
            },
            onEdit: { [weak self] item in self?.beginEdit(item) },
            onCopy: { [weak self] item in self?.copyWithoutPasting(item) },
            onRevealInFinder: { [weak self] item in self?.revealInFinder(item) },
            onDelete: { item in
                Task { await ClipboardHistoryStore.shared.delete(item) }
            },
            onToggleTag: { item, tagID in
                Task { await ClipboardHistoryStore.shared.toggleTag(item, tagID: tagID) }
            },
            onNewTag: { [weak self] item in
                // A floating text preview must not stay over the modal overlay,
                // but a dirty editor resolves its discard prompt first.
                guard ClipboardTextWindow.shared.yieldToModal() else { return }
                self?.state.presentTagDialog(.create(item: item))
            },
            onIgnoreSource: { [weak self] item in self?.ignoreSource(item) },
            onTagDialogCommit: { [weak self] in self?.commitTagDialog() },
            onTagDialogCancel: { [weak self] in self?.cancelTagDialog() },
            registerSearchField: { [weak self] field in self?.searchField = field }
        )
        if let modelContainer {
            return AnyView(view.modelContainer(modelContainer))
        }
        return AnyView(view)
    }

    /// Build and install a fresh SwiftUI host. The view is @Query-backed, so a
    /// fresh host re-subscribes and re-renders on store changes on every open.
    private func installHostingView() {
        let host = NSHostingView(rootView: makeWallView())
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        hostingView = host
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainThreadIsolation.run { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        // Translate the scroll wheel / trackpad swipe into card navigation; the
        // horizontal ScrollView otherwise ignores a plain vertical mouse wheel.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainThreadIsolation.run { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }
        // Track ⌥ so the view can enable tab drag-to-reorder reactively.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainThreadIsolation.run {
                self?.state.isReorderModifierHeld = event.modifierFlags.contains(.option)
            }
            return event
        }
        // A global mouse-down fires only for clicks NOT delivered to our app —
        // i.e. anywhere outside the wall — so any such click dismisses it.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run {
                guard let self else { return }
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
                // Don't throw away an in-progress edit on a stray outside click.
                if ClipboardTextWindow.shared.isEditing { return }
                self.dismiss(restoreFocus: false)
            }
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, scrollMonitor, flagsMonitor, globalMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        scrollMonitor = nil
        flagsMonitor = nil
        globalMouseMonitor = nil
        scrollAccum = 0
    }

    /// Step the selection as scroll delta accumulates past `scrollStep`. Uses
    /// whichever axis dominates so both a vertical mouse wheel and a horizontal
    /// trackpad swipe flip through the cards. Negative delta advances right.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        // Only convert scrolls over the wall itself into card navigation. A
        // scroll targeting any other window — the floating text panel, or an
        // open NSMenu such as the source filter — must reach that window rather
        // than being swallowed here (otherwise the menu can't scroll and the
        // cards advance under it). This subsumes the old floating-text-panel
        // check, since that panel is a different window.
        guard event.window === window else { return false }
        // The selection must not change behind the tag dialog's modal dimmer.
        if state.tagDialog != nil { return true }
        // The top strip (tab row + search field) hosts its own horizontal
        // ScrollView; let scrolls over that area reach it instead of becoming
        // card navigation.
        if event.locationInWindow.y > window.contentLayoutRect.maxY - Self.topStripHeight {
            return false
        }
        // Ignore trackpad inertia so flicking doesn't keep advancing after the
        // fingers lift; only act on the user's active scroll.
        guard event.momentumPhase == [] else { return true }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccum += delta
        while scrollAccum <= -Self.scrollStep { state.moveRight(); scrollAccum += Self.scrollStep }
        while scrollAccum >= Self.scrollStep { state.moveLeft(); scrollAccum -= Self.scrollStep }
        syncTextPreview()
        return true
    }

    /// Route a key press by mode. In input mode the search field owns most keys
    /// (text editing + IME), so we only intercept Esc and Enter and let the rest
    /// fall through to the field; the field's own delegate hands focus back to
    /// card navigation when → is pressed at the end of a non-empty query. In card
    /// navigation mode arrows move the selection, Enter pastes, and typing a
    /// printable character focuses the field (type-to-search). Returns whether
    /// the event was consumed (a returned event keeps flowing to the field).
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        // While the tag dialog overlay is up it owns the keyboard: Return
        // commits, Esc cancels, everything else flows to its text field.
        // Checked before routeToTextWindow so a floating preview can't eat
        // Space / e / Esc while the user types a tag name.
        if state.tagDialog != nil {
            switch event.keyCode {
            case 53:
                // Esc mid-composition cancels the IME marked text, not the dialog.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                cancelTagDialog(); return true
            case 36, 76:
                // Let Return commit an in-flight IME composition instead of
                // the dialog; the composed text lands in the field first.
                if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
                commitTagDialog(); return true
            default: return false
            }
        }
        if let consumed = routeToTextWindow(event) { return consumed }
        // ⌘K opens the source-filter menu, in both input and card-navigation
        // modes (intercepted before the input-mode passthrough below).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            state.requestOpenSourceMenu()
            return true
        }
        let inputMode = state.isSearchFocused
        switch event.keyCode {
        case 53:                                         // esc — staged exit
            if state.query.isEmpty {
                // Nothing to step back through: close outright, in either mode.
                dismiss(restoreFocus: true)
            } else if inputMode {
                // A non-empty query clears first, leaving the field focused.
                state.query = ""; searchField?.stringValue = ""
            } else {
                // Card navigation over a search → return focus to edit/clear it.
                state.isSearchFocused = true
            }
            return true
        case 36, 76:                                     // ↵ / numpad enter
            if let item = state.selectedItem {
                paste(item, plain: event.modifierFlags.contains(.option))
            }
            return true
        case 123:                                        // ←
            if inputMode { return false }                // move the text caret
            state.moveLeft(); syncTextPreview(); return true
        case 124:                                        // →
            if inputMode { return false }                // field delegate may exit
            state.moveRight(); syncTextPreview(); return true
        case 49:                                         // space
            if inputMode { return false }                // insert a space
            togglePreview(); return true
        case 48:                                         // tab — cycle category tabs
            // Works in both modes; the field never needs a literal tab. The
            // filtered list changes, so drop an open text preview rather than
            // leave it showing an item from the previous tab.
            if ClipboardTextWindow.shared.isPreviewVisible { ClipboardTextWindow.shared.close() }
            if event.modifierFlags.contains(.shift) {
                state.selectPreviousCategory()
            } else {
                state.selectNextCategory()
            }
            return true
        case 51:                                         // ⌫
            if inputMode { return false }                // delete a character
            if let item = state.selectedItem {
                // The preview would otherwise keep showing the deleted item.
                if ClipboardTextWindow.shared.isPreviewVisible { ClipboardTextWindow.shared.close() }
                Task { await ClipboardHistoryStore.shared.delete(item) }
            }
            return true
        default:
            if inputMode { return false }                // field inserts / composes
            return focusSearchOnType(event)
        }
    }

    /// Keys claimed by the floating text panel while it is up. Returns nil when
    /// the event should flow to the wall's normal handling instead.
    private func routeToTextWindow(_ event: NSEvent) -> Bool? {
        let textWindow = ClipboardTextWindow.shared
        if textWindow.isEditing {
            if event.keyCode == 53 {                     // esc → dirty-checked close
                textWindow.requestClose(); return true
            }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "s" {
                textWindow.saveRequested(); return true  // ⌘S → save
            }
            // Everything else (typing, ⌘Z, arrows…) belongs to the key editor.
            return false
        }
        if textWindow.isPreviewVisible {
            switch event.keyCode {
            case 53, 49:                                 // esc / space close it
                textWindow.close(); return true
            default:
                // Plain "e" swaps the preview for the editor (the preview
                // header shows the hint); other keys fall through so arrows
                // and type-to-search keep working.
                if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                   event.charactersIgnoringModifiers?.lowercased() == "e" {
                    textWindow.requestEditFromPreview()
                    return true
                }
                return nil
            }
        }
        return nil
    }

    /// Type-to-search from card navigation: a printable keystroke focuses the
    /// search field and is then delivered to it (the event is returned, not
    /// consumed, so the same press lands in the now-first-responder field —
    /// keeping IME composition intact). Modifier combos and control keys are
    /// ignored. The caret is parked at the end so an existing query is appended
    /// to rather than replaced.
    private func focusSearchOnType(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .function])
        guard modifiers.isEmpty,
              let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let field = searchField
        else { return false }
        // Focus is moving into the search field; a floating preview would now
        // swallow Space/Esc meant for the query, so drop it (it's stale anyway —
        // searching is about to change the selection).
        if ClipboardTextWindow.shared.isPreviewVisible { ClipboardTextWindow.shared.close() }
        window?.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        state.isSearchFocused = true
        return false
    }

    private func paste(_ item: ClipboardHistoryItem, plain: Bool) {
        if !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        let pb = NSPasteboard.general
        ClipboardPasteService.writePayload(for: item, asPlainText: plain, to: pb, historyDirectory: historyDirectory)
        watcher?.noteSelfWrite(changeCount: pb.changeCount)
        // Slide out first; reactivating the prior app returns focus there, so
        // the synthesized ⌘V lands in it rather than on our panel.
        dismiss(restoreFocus: true) { [copyOnly = ClipboardPreferences.copyOnly] in
            guard !copyOnly else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                ClipboardPasteService.synthesizePaste()
            }
        }
    }

    // MARK: - Context-menu actions

    /// "Edit" from a card's context menu: open the floating text editor. The
    /// wall stays open behind it (windowDidResignKey exempts the text panel);
    /// key status returns to the wall when the editor closes.
    private func beginEdit(_ item: ClipboardHistoryItem) {
        guard item.historyKind?.isTextBearing == true else { return }
        ClipboardTextWindow.shared.showEditor(item: item) { [weak self] in
            self?.window?.makeKey()
        }
    }

    /// "Copy" from a card's context menu: write the payload to the pasteboard
    /// without pasting or dismissing the wall.
    private func copyWithoutPasting(_ item: ClipboardHistoryItem) {
        guard ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) else {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        let pb = NSPasteboard.general
        ClipboardPasteService.writePayload(for: item, asPlainText: false, to: pb, historyDirectory: historyDirectory)
        // Suppress the watcher so the re-copy isn't captured as a duplicate.
        watcher?.noteSelfWrite(changeCount: pb.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// "Reveal in Finder" from a file card's context menu. Prefers each entry's
    /// original path; falls back to the stored copy when the original is gone.
    /// Activating Finder resigns the wall's key status and dismisses it, which
    /// is fine — the user is leaving for Finder anyway.
    private func revealInFinder(_ item: ClipboardHistoryItem) {
        let fm = FileManager.default
        let urls = item.files.compactMap { entry -> URL? in
            if fm.fileExists(atPath: entry.originalPath) {
                return URL(fileURLWithPath: entry.originalPath)
            }
            if let stored = entry.storedName {
                let copy = historyDirectory.appendingPathComponent(stored)
                if fm.fileExists(atPath: copy.path) { return copy }
            }
            return nil
        }
        guard !urls.isEmpty else {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// "Ignore Source App" from a card's context menu: future captures from
    /// that app are skipped by ClipboardWatcher. Existing history stays intact.
    private func ignoreSource(_ item: ClipboardHistoryItem) {
        guard let bundleID = item.sourceBundleID else { return }
        ClipboardPreferences.addExcludedBundleID(bundleID)
        let name = item.sourceAppName ?? bundleID
        ToastPresenter.shared.show(.success(L(.clipboardToastSourceIgnored, name)))
    }

    // MARK: - Tag dialog

    /// Commit the in-wall tag dialog. Create assigns the new (or existing
    /// same-named) tag to the right-clicked item in one step; rename and
    /// delete go through the registry, and delete additionally sweeps the id
    /// off all items so they regain prunability.
    private func commitTagDialog() {
        guard let dialog = state.tagDialog else { return }
        switch dialog {
        case .create(let item):
            // Empty name → keep the dialog open instead of silently closing.
            guard let tag = ClipboardTagStore.shared.createTag(name: state.tagDialogText) else { return }
            // The item may have been deleted or pruned while the dialog was
            // up; writing to a deleted PersistentModel is undefined.
            if !item.isDeleted, !item.tagIDs.contains(tag.id) {
                Task { await ClipboardHistoryStore.shared.toggleTag(item, tagID: tag.id) }
            }
        case .rename(let tagID):
            let trimmed = state.tagDialogText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            ClipboardTagStore.shared.renameTag(id: tagID, to: trimmed)
        case .confirmDelete(let tagID):
            ClipboardTagStore.shared.deleteTag(id: tagID)
            Task { await ClipboardHistoryStore.shared.removeTagFromAllItems(tagID) }
        }
        cancelTagDialog()
    }

    private func cancelTagDialog() {
        state.tagDialog = nil
        state.tagDialogText = ""
    }

    // MARK: - Quick Look (space)

    /// Space: text-bearing kinds open the floating text panel; image/screenshot/
    /// file go through system Quick Look; color has no preview (the card already
    /// shows the value).
    private func togglePreview() {
        guard let item = state.selectedItem else { return }
        if item.historyKind?.isTextBearing == true {
            if ClipboardTextWindow.shared.isPreviewVisible {
                ClipboardTextWindow.shared.close()
            } else {
                ClipboardTextWindow.shared.showPreview(item: item)
            }
            return
        }
        toggleQuickLook()
    }

    /// Keep an open text preview in step with the keyboard selection (Finder
    /// Quick Look behavior). Closes it when the selection leaves text kinds.
    private func syncTextPreview() {
        guard ClipboardTextWindow.shared.isPreviewVisible else { return }
        if let item = state.selectedItem, item.historyKind?.isTextBearing == true {
            ClipboardTextWindow.shared.showPreview(item: item)
        } else {
            ClipboardTextWindow.shared.close()
        }
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        previewURL = quickLookURL(for: state.selectedItem)
        guard previewURL != nil else { return }
        panel.dataSource = self
        panel.makeKeyAndOrderFront(nil)
    }

    private func quickLookURL(for item: ClipboardHistoryItem?) -> URL? {
        guard let item, let kind = item.historyKind else { return nil }
        switch kind {
        case .image, .screenshot:
            guard let f = item.fileName else { return nil }
            return historyDirectory.appendingPathComponent(f)
        case .file:
            if let stored = item.files.first?.storedName { return historyDirectory.appendingPathComponent(stored) }
            if let path = item.files.first?.originalPath { return URL(fileURLWithPath: path) }
            return nil
        default:
            return nil   // text/color preview is already visible on the card
        }
    }

    // QLPreviewPanelDataSource is not main-actor annotated, but Quick Look only
    // invokes these on the main thread. Mark them nonisolated and hop back onto
    // the main actor to read the main-actor-isolated previewURL.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainThreadIsolation.run { previewURL == nil ? 0 : 1 }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainThreadIsolation.run { previewURL as NSURL? }
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
    }
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while Quick Look or the floating text panel is up — the
        // text editor takes key status while the wall stays open behind it.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        if ClipboardTextWindow.shared.isVisible { return }
        // Ignore the resign that the slide-out animation itself triggers.
        guard !isAnimating else { return }
        // A click elsewhere already moved focus; don't yank it back.
        dismiss(restoreFocus: false)
    }
}

/// A borderless panel that can still become key. NSWindow refuses key status
/// for borderless windows by default, which would leave the wall unable to
/// receive keyboard events; overriding `canBecomeKey` lets it become key via
/// the .nonactivatingPanel style without activating AnyDoor — so the prior app
/// stays active and does not visibly lose focus.
final class ClipboardWallPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
