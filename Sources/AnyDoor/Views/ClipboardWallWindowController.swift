import AppKit
import ClipboardHistory
import PluginInterface
import PluginSupport
import QuartzCore
import SwiftUI

/// Bottom, full-width overlay that hosts the clipboard card wall. Summoned by
/// the clipboard-wall hotkey (via ClipboardWallProvider) or the panel row.
/// Mirrors CommandPaletteWindowController's activation/key-monitor pattern.
@MainActor
final class ClipboardWallWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClipboardWallWindowController()

    private var configuredState: ClipboardWallState?
    private var clipboardHistoryLifecycle: ClipboardHistoryLifecycle?
    private var state: ClipboardWallState {
        guard let configuredState else {
            preconditionFailure(
                "ClipboardWallWindowController must be configured before use"
            )
        }
        return configuredState
    }
    /// Rebuilt fresh on every show so an ordered-out host cannot retain stale
    /// observation state. A LazyHStack keeps the rebuild cheap.
    private var hostingView: NSHostingView<AnyView>?
    /// The wall's search field, published by `WallSearchField`. Held so the key
    /// monitor can make it first responder synchronously for type-to-focus.
    private weak var searchField: NSTextField?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var flagsMonitor: Any?
    private var globalMouseMonitor: Any?
    private var previewTask: Task<Void, Never>?
    /// The in-flight ⌘→ step. Held so a key repeat can be dropped instead of
    /// stacking page requests behind a held-down arrow.
    private var endNavigationTask: Task<Void, Never>?
    /// Accumulated scroll delta; selection advances each time it crosses a step.
    private var scrollAccum: CGFloat = 0
    private static let scrollStep: CGFloat = 40
    /// Height of the wall's top strip (14pt top padding + tab/search row) where
    /// scrolls belong to the tab row's own horizontal ScrollView, not card
    /// navigation. Keep in sync with ClipboardWallView's layout.
    private static let topStripHeight: CGFloat = 48

    /// The app that was frontmost when the wall opened. The wall activates
    /// AnyDoor so its panel can become key (a background .accessory app's panel
    /// won't otherwise receive keyboard events); focus is returned here on
    /// paste/Esc so the net effect is no focus theft.
    private weak var previousApp: NSRunningApplication?

    /// Guards against re-entrant show/dismiss while the slide animation runs.
    private var isAnimating = false
    private static let panelHeight: CGFloat = 325
    private static let animationDuration: TimeInterval = 0.22

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
        // The wall opens in card-navigation mode: never let AppKit's key-view
        // loop pick the search field as the initial first responder when the
        // panel becomes key (Tab is intercepted for category cycling, so the
        // loop is unused anyway).
        panel.autorecalculatesKeyViewLoop = false
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(
        module: ClipboardHistoryModule,
        lifecycle: ClipboardHistoryLifecycle
    ) {
        guard configuredState == nil else { return }
        configuredState = ClipboardWallState(
            presentation: ClipboardHistoryPresentationModel(module: module)
        )
        clipboardHistoryLifecycle = lifecycle
    }

    func toggle() {
        guard configuredState != nil, !isAnimating else { return }
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
        state.sourceFilterID = nil
        // Open in card-navigation mode (search field unfocused); typing focuses
        // it. Reset here so a prior session's focus state never leaks in.
        state.isSearchFocused = false
        // Never resurface a stale tag dialog (it may pin a deleted item).
        state.tagDialog = nil
        state.tagDialogText = ""
        // Seed from the live flags: ⌥ may already be held when the wall opens,
        // and the monitor only reports subsequent changes.
        state.isReorderModifierHeld = NSEvent.modifierFlags.contains(.option)
        // Selection joins the reset above: the wall always opens at the
        // newest entry. A deep selection retained from the previous session
        // would otherwise centre the render window far from the head while
        // the fresh scroll view sits at offset zero — showing only the
        // leading pad's blank space, with nothing firing a scroll-to (the
        // selected index has not changed, so onChange stays quiet).
        state.moveToStart()
        // Mount only a viewport-sized opening window for the slide-in — sized
        // from the actual screen, so a laptop mounts far fewer cards than a
        // 5K display — and grow to the full sticky window in slices once the
        // animation has finished (see the completion handler below), keeping
        // the eager row's mount cost off the open path.
        let screenWidth = NSScreen.main?.frame.width ?? 2000
        state.beginConstrainedMount(
            radius: Int((screenWidth / 2 / 240).rounded(.up)) + 3
        )
        installHostingView()
        installMonitors()
        // Preview → editor handoff ("e" key / the preview header's edit
        // button) goes down the same path as the card's context menu.
        ClipboardTextWindow.shared.onEditRequest = { [weak self] item in self?.beginEdit(item) }
        // Preview copy ("c" key / the preview header's copy button) writes the
        // item to the pasteboard down the same path as the card's context menu.
        ClipboardTextWindow.shared.onCopyRequest = { [weak self] item in self?.copyWithoutPasting(item) }

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
        // Safety net: if becoming key still handed first responder to the
        // search field through any path we didn't defeat above, take it back —
        // the field reports the resign so state ends up in card navigation.
        if window.firstResponder !== window { window.makeFirstResponder(nil) }
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            MainThreadIsolation.run {
                self?.isAnimating = false
                self?.configuredState?.expandMountAfterOpening()
            }
        })
    }

    /// Slide the panel down off-screen, then close it. When `restoreFocus` is
    /// true the previously frontmost app is reactivated first (Esc / paste);
    /// for a click elsewhere it is false, since that click already moved focus.
    /// `completion` runs after the window has ordered out, so paste can post ⌘V
    /// once focus has returned. No-op if already hidden or mid-animation.
    private func dismiss(restoreFocus: Bool, completion: (@Sendable () -> Void)? = nil) {
        // The floating panels have no life of their own once the wall goes away.
        closePreviews()
        guard !isAnimating, let window, window.isVisible, let screen = NSScreen.main else {
            completion?()
            return
        }
        if restoreFocus { restorePreviousApplicationFocus() }
        configuredState?.cancelMountExpansion()
        freezeContentForDismissal()
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

    /// Restore the app that owned keyboard focus before the wall opened.
    /// `NSRunningApplication.activate()` is ignored in this situation on
    /// macOS 14+, because AnyDoor is an accessory app. Launch Services is
    /// allowed to honor the user-initiated focus transfer before we synthesize
    /// Command-V.
    private func restorePreviousApplicationFocus() {
        guard let previousApp, !previousApp.isActive else { return }
        guard let bundleURL = previousApp.bundleURL else {
            previousApp.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        ) { _, _ in }
    }

    private func makeWallView() -> AnyView {
        let view = ClipboardWallView(
            state: state,
            onSelect: { [weak self] item, plain in self?.paste(item, plain: plain) },
            onToggleFavorite: { [weak self] item in
                self?.performMutation(
                    .setFavorite(item.id, !item.isFavorite)
                )
            },
            onEdit: { [weak self] item in self?.beginEdit(item) },
            onCopy: { [weak self] item in self?.copyWithoutPasting(item) },
            onPluginAction: { [weak self] owner, action, payload in
                self?.performPluginAction(
                    action,
                    owner: owner,
                    payload: payload
                )
            },
            onRevealInFinder: { [weak self] item in self?.revealInFinder(item) },
            onDelete: { [weak self] item in
                self?.performMutation(.delete(item.id))
            },
            onToggleTag: { [weak self] item, tagID in
                var tagIDs = item.tagIDs
                if !tagIDs.insert(tagID).inserted {
                    tagIDs.remove(tagID)
                }
                self?.performMutation(.setTags(item.id, tagIDs))
            },
            onNewTag: { [weak self] item in
                // A floating preview must not stay over the modal overlay,
                // but a dirty editor resolves its discard prompt first.
                ClipboardQuickLookWindow.shared.close()
                guard ClipboardTextWindow.shared.yieldToModal() else { return }
                self?.state.presentTagDialog(.create(entryID: item.id))
            },
            onIgnoreSource: { [weak self] item in self?.ignoreSource(item) },
            onTagDialogCommit: { [weak self] in self?.commitTagDialog() },
            onTagDialogCancel: { [weak self] in self?.cancelTagDialog() },
            registerSearchField: { [weak self] field in self?.searchField = field }
        )
        return AnyView(view)
    }

    /// Build and install a fresh SwiftUI host on every open.
    /// Swap the live SwiftUI content for a bitmap snapshot before the
    /// slide-out. The hosting view is rebuilt fresh on every show anyway,
    /// and freezing it here makes the dismiss animation immune to
    /// main-thread SwiftUI work — mount-expansion slices, materialization
    /// results still landing on mounted cards — that would otherwise starve
    /// the window animator's frames.
    private func freezeContentForDismissal() {
        guard let window, let hostingView,
            hostingView.bounds.width > 0, hostingView.bounds.height > 0,
            let bitmap = hostingView.bitmapImageRepForCachingDisplay(
                in: hostingView.bounds
            )
        else { return }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let image = NSImage(size: hostingView.bounds.size)
        image.addRepresentation(bitmap)
        let imageView = NSImageView(image: image)
        imageView.frame = hostingView.frame
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        window.contentView = imageView
        self.hostingView = nil
    }

    private func installHostingView() {
        let host = NSHostingView(rootView: makeWallView())
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        // Setting contentView can (re)assign initialFirstResponder to the first
        // focusable view — the search field — which would auto-focus it the
        // moment the panel becomes key. The wall must open unfocused.
        window?.initialFirstResponder = nil
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
        // A page fetch started by ⌘→ has no one left to follow it once the wall
        // is gone; the next show reloads from the first page anyway.
        endNavigationTask?.cancel()
        endNavigationTask = nil
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
        syncPreview()
        return true
    }

    /// Route a key press by mode. In input mode the search field owns most keys
    /// (text editing + IME), so we only intercept Esc, Enter, and ↓ (which hands
    /// focus back to card navigation) and let the rest fall through to the
    /// field. In card navigation mode arrows move the selection, Enter pastes,
    /// and ⌘F focuses the search field — the wall never focuses it implicitly.
    /// Returns whether the event was consumed (a returned event keeps flowing
    /// to the field).
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
                if window.hasIMEComposition { return false }
                cancelTagDialog(); return true
            case 36, 76:
                // Let Return commit an in-flight IME composition instead of
                // the dialog; the composed text lands in the field first.
                if window.hasIMEComposition { return false }
                commitTagDialog(); return true
            default: return false
            }
        }
        if let consumed = routeToTextWindow(event) { return consumed }
        // Same IME rule as the tag dialog above, for the search field: while
        // a composition is in flight, Return / Esc / Tab belong to the input
        // method, not to paste / staged-exit / tab-cycling.
        if window.isKeyWindow, window.hasIMEComposition { return false }
        // ⌘K opens the source-filter menu, in both input and card-navigation
        // modes (intercepted before the input-mode passthrough below).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "k" {
            state.requestOpenSourceMenu()
            return true
        }
        // ⌘F toggles input mode: focus the search field from card navigation,
        // and hand the keyboard back to the cards when pressed again while the
        // field is focused — keeping the query (Esc is the one that clears).
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            if state.isSearchFocused {
                window.makeFirstResponder(nil)
            } else {
                focusSearchField()
            }
            return true
        }
        let inputMode = state.isSearchFocused
        switch event.keyCode {
        case 53:                                         // esc — staged exit
            // An open Quick Look preview is the first thing Esc steps back
            // through (the floating text panel handles its own Esc in
            // routeToTextWindow above); the wall stays up.
            if ClipboardQuickLookWindow.shared.isVisible {
                ClipboardQuickLookWindow.shared.close()
            } else if state.query.isEmpty {
                // Nothing to step back through: close outright, in either mode.
                dismiss(restoreFocus: true)
            } else if inputMode {
                // A non-empty query clears first, leaving the field focused;
                // WallSearchField syncs the field text from state.query.
                state.query = ""
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
        case 123:                                        // ← / ⌘← (jump to first)
            if inputMode { return false }                // move the text caret
            if event.modifierFlags.contains(.command) { state.moveToStart() }
            else { state.moveLeft() }
            syncPreview(); return true
        case 124:                                        // → / ⌘→ (toward the end)
            if inputMode { return false }                // move the text caret
            if event.modifierFlags.contains(.command) {
                // Consumed here and now; the step itself may need a page fetch,
                // so it finishes asynchronously and syncs the preview then.
                moveTowardHistoryEnd()
                return true
            }
            state.moveRight()
            syncPreview(); return true
        case 125:                                        // ↓ — leave the search field
            guard inputMode else { return false }
            // Hand the keyboard back to card navigation. Resign synchronously
            // (not via state) so the very next keystroke already routes to the
            // cards; the field reports the focus change into state itself.
            window.makeFirstResponder(nil)
            return true
        case 49:                                         // space
            if inputMode { return false }                // insert a space
            togglePreview(); return true
        case 48:                                         // tab — cycle category tabs
            // Works in both modes; the field never needs a literal tab. The
            // filtered list changes, so drop an open preview rather than leave
            // it showing an item from the previous tab.
            closePreviews()
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
                closePreviews()
                performMutation(.delete(item.id))
            }
            return true
        default:
            if inputMode { return false }                // field inserts / composes
            // No type-to-search: the field is only focused explicitly (⌘F or a
            // click). Swallow plain printable keys so stray typing in card
            // navigation doesn't fall through to the window and beep.
            return isPlainPrintable(event)
        }
    }

    /// ⌘→: select the loaded tail, or — when already there — load one more page
    /// and follow it.
    ///
    /// The key event is consumed synchronously by the caller and the step runs
    /// in a single retained task. A repeat arriving while that task is in flight
    /// is dropped rather than queued: holding the arrow down must not stack page
    /// requests, and each press has to be able to observe where the previous one
    /// landed before it decides whether to fetch at all.
    private func moveTowardHistoryEnd() {
        guard endNavigationTask == nil else { return }
        endNavigationTask = Task { [weak self] in
            guard let self else { return }
            await state.moveToEnd()
            // Cancelled means the wall closed under the fetch and this slot may
            // already belong to a later press; leave it alone.
            guard !Task.isCancelled else { return }
            endNavigationTask = nil
            // An open preview follows the selection this step ended on, not the
            // one the key press started from.
            syncPreview()
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
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                textWindow.requestClose(); return true   // ⌘W → dirty-checked close
            }
            // Everything else (typing, ⌘Z, arrows…) belongs to the key editor.
            return false
        }
        if textWindow.isPreviewVisible {
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘C copies the current text selection, falling back to the whole
            // item when nothing is selected. The preview panel is non-key, so
            // the standard copy: responder chain never reaches its text view —
            // handle it here instead.
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
                copyPreviewSelection()
                return true
            }
            if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
                textWindow.close(); return true          // ⌘W → close preview
            }
            switch event.keyCode {
            case 53, 49:                                 // esc / space close it
                textWindow.close(); return true
            default:
                // Plain "e" swaps the preview for the editor and plain "c"
                // copies the whole item to the pasteboard (the preview header
                // shows both hints); other keys fall through so arrows and
                // type-to-search keep working.
                if mods.isEmpty {
                    switch event.charactersIgnoringModifiers?.lowercased() {
                    case "e":
                        textWindow.requestEditFromPreview()
                        return true
                    case "c":
                        textWindow.requestCopyFromPreview()
                        return true
                    default:
                        break
                    }
                }
                return nil
            }
        }
        return nil
    }

    /// ⌘F: enter input mode. Makes the field first responder synchronously (so
    /// the very next keystroke can start an IME composition in it) with the
    /// caret parked at the end, appending to any existing query.
    /// `state.isSearchFocused` is not written here: the field reports the focus
    /// change itself, so a refused `makeFirstResponder` can never strand the
    /// state in input mode.
    private func focusSearchField() {
        // Focus is moving into the search field; a floating preview would now
        // swallow Space/Esc meant for the query, so drop it (it's stale anyway —
        // searching is about to change the selection).
        closePreviews()
        guard let field = searchField, field.window === window else {
            // The reference can lag a host rebuild; command focus through
            // state and let updateNSView grab first responder on the next
            // render instead of dropping the shortcut.
            state.isSearchFocused = true
            return
        }
        window?.makeFirstResponder(field)
        let end = (field.stringValue as NSString).length
        field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
    }

    /// A bare printable keystroke (no ⌘/⌃/⌥/fn, no control characters) — the
    /// kind that used to trigger type-to-search and now gets swallowed in card
    /// navigation.
    private func isPlainPrintable(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .function])
        guard modifiers.isEmpty,
              let characters = event.characters, !characters.isEmpty else { return false }
        return characters.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private func paste(
        _ entry: ClipboardHistoryEntry,
        plain: Bool
    ) {
        Task {
            let purpose: ClipboardHistoryMaterializationPurpose =
                plain ? .plainTextPaste : .normalPaste
            guard let materialization =
                await state.presentation.materialization(
                    for: entry.id,
                    purpose: purpose,
                    usesCache: false
                )
            else {
                presentActionFailure()
                return
            }
            do {
                try ClipboardSelfWrites.perform { pasteboard in
                    try ClipboardHistoryPasteService.write(
                        materialization,
                        to: pasteboard
                    )
                }
            } catch {
                ClipboardHistoryActionFailurePresenter.present(.unknown)
                return
            }
            // Slide out first; reactivating the prior app returns focus there,
            // so the synthesized Command-V lands in it rather than on our panel.
            dismiss(restoreFocus: true) {
                [copyOnly = ClipboardPreferences.copyOnly] in
                guard !copyOnly else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    ClipboardHistoryPasteService.synthesizePaste()
                }
            }
        }
    }

    // MARK: - Context-menu actions

    /// "Edit" from a card's context menu: open the floating text editor. The
    /// wall stays open behind it (windowDidResignKey exempts the text panel);
    /// key status returns to the wall when the editor closes.
    private func beginEdit(_ entry: ClipboardHistoryEntry) {
        Task {
            guard let materialization =
                await state.presentation.materialization(
                    for: entry.id,
                    purpose: .hostAction
                ),
                let text = materialization.editableText
            else {
                presentActionFailure()
                return
            }
            ClipboardTextWindow.shared.showEditor(
                entry: entry,
                text: text,
                onSave: { [weak self] text in
                    self?.performMutation(.editText(entry.id, text))
                },
                onClose: { [weak self] in
                    self?.window?.makeKey()
                }
            )
        }
    }

    /// "Copy" from a card's context menu: write the payload to the pasteboard
    /// without pasting or dismissing the wall.
    private func copyWithoutPasting(_ entry: ClipboardHistoryEntry) {
        Task {
            guard let materialization =
                await state.presentation.materialization(
                    for: entry.id,
                    purpose: .normalPaste,
                    usesCache: false
                )
            else {
                presentActionFailure()
                return
            }
            do {
                try ClipboardSelfWrites.perform { pasteboard in
                    try ClipboardHistoryPasteService.write(
                        materialization,
                        to: pasteboard
                    )
                }
                ToastPresenter.shared.show(
                    .success(L(.toastCopiedToClipboard))
                )
            } catch {
                ClipboardHistoryActionFailurePresenter.present(.unknown)
            }
        }
    }

    /// ⌘C in the read-only preview: copy the current text selection to the
    /// pasteboard, or the whole item when nothing is selected. Keeps the
    /// preview and wall open, mirroring `copyWithoutPasting`.
    private func copyPreviewSelection() {
        guard let selection = ClipboardTextWindow.shared.selectedPreviewText(),
              !selection.isEmpty else {
            if let entry = ClipboardTextWindow.shared.previewedEntry {
                copyWithoutPasting(entry)
            }
            return
        }
        ClipboardSelfWrites.write(string: selection)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }

    /// `apply` already patches the loaded page (and refetches itself when the
    /// mutation can change page membership), so this must not reload on top of
    /// it — that would snap a deep scroll position back to the first page after
    /// every delete or favourite toggle.
    private func performMutation(_ mutation: ClipboardHistoryMutation) {
        Task {
            await state.presentation.apply(mutation)
            if state.presentation.actionFailure != nil {
                presentActionFailure()
            }
        }
    }

    private func presentActionFailure() {
        if case .fileCollectionRequiresRestore(
            let entryID,
            let ownedCount,
            _
        ) = state.presentation.actionFailure,
            ownedCount > 0
        {
            Task { await restoreLegacyFiles(for: entryID) }
            return
        }
        ClipboardHistoryActionFailurePresenter.present(
            state.presentation.actionFailure
        )
    }

    private func restoreLegacyFiles(
        for entryID: ClipboardHistoryEntryID
    ) async {
        guard let plan =
            await state.presentation.legacyFileRestorePlan(for: entryID),
            !plan.ownedMembers.isEmpty
        else {
            ClipboardHistoryActionFailurePresenter.present(
                state.presentation.actionFailure
            )
            return
        }
        guard let destinations = chooseRestoreDestinations(for: plan) else {
            return
        }
        await performRestore(plan: plan, destinations: destinations)
    }

    private func chooseRestoreDestinations(
        for plan: ClipboardHistoryLegacyFileRestorePlan
    ) -> [ClipboardHistoryLegacyFileDestination]? {
        if plan.ownedMembers.count == 1,
            let member = plan.ownedMembers.first
        {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = member.suggestedName
            panel.title = L(.clipboardRestoreFile)
            guard panel.runModal() == .OK, let url = panel.url else {
                return nil
            }
            return [
                ClipboardHistoryLegacyFileDestination(
                    memberID: member.id,
                    url: url
                )
            ]
        }

        let panel = NSOpenPanel()
        panel.title = L(.clipboardRestoreFiles)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else {
            return nil
        }
        var usedNames = Set<String>()
        return plan.ownedMembers.map { member in
            let name = uniqueRestoreName(
                member.suggestedName,
                usedNames: &usedNames
            )
            return ClipboardHistoryLegacyFileDestination(
                memberID: member.id,
                url: directory.appendingPathComponent(name)
            )
        }
    }

    private func uniqueRestoreName(
        _ suggestedName: String,
        usedNames: inout Set<String>
    ) -> String {
        let safeName = URL(fileURLWithPath: suggestedName)
            .lastPathComponent
        let initial = safeName.isEmpty ? "Restored File" : safeName
        guard !usedNames.contains(initial) else {
            let url = URL(fileURLWithPath: initial)
            let stem = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            var suffix = 2
            while true {
                let candidate = ext.isEmpty
                    ? "\(stem) \(suffix)"
                    : "\(stem) \(suffix).\(ext)"
                if usedNames.insert(candidate).inserted {
                    return candidate
                }
                suffix += 1
            }
        }
        usedNames.insert(initial)
        return initial
    }

    private func performRestore(
        plan: ClipboardHistoryLegacyFileRestorePlan,
        destinations: [ClipboardHistoryLegacyFileDestination]
    ) async {
        let existing = destinations.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        var effectiveDestinations = destinations
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = L(.clipboardRestoreCollisionTitle)
            alert.informativeText = L(.clipboardRestoreCollisionMessage)
            alert.alertStyle = .warning
            alert.addButton(
                withTitle: L(.clipboardRestoreReuseIdentical)
            )
            alert.addButton(
                withTitle: L(.clipboardRestoreChooseAnother)
            )
            alert.addButton(withTitle: L(.settingsPanelCancel))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let existingURLs = Set(existing.map(\.url))
                effectiveDestinations = destinations.map { destination in
                    ClipboardHistoryLegacyFileDestination(
                        memberID: destination.memberID,
                        url: destination.url,
                        collisionPolicy:
                            existingURLs.contains(destination.url)
                            ? .reuseIfIdentical
                            : .failIfExists
                    )
                }
            case .alertSecondButtonReturn:
                guard let replacement =
                    chooseRestoreDestinations(for: plan)
                else {
                    return
                }
                await performRestore(
                    plan: plan,
                    destinations: replacement
                )
                return
            default:
                return
            }
        }

        let request = ClipboardHistoryLegacyFileRestoreRequest(
            entryID: plan.entryID,
            destinations: effectiveDestinations
        )
        if await state.presentation.restoreLegacyOwnedFiles(request) {
            await state.presentation.reload()
        } else {
            ClipboardHistoryActionFailurePresenter.present(
                state.presentation.actionFailure
            )
        }
    }

    /// A plugin-contributed action from a card's context menu, routed back
    /// through the registry so this controller never names the plugin behind
    /// it. The plugin decides whether to dismiss the wall via the context
    /// (e.g. before presenting its own window) — a failure it reports itself
    /// leaves the wall open.
    private func performPluginAction(
        _ action: PluginClipboardAction,
        owner: NativePluginID,
        payload: PluginClipboardPayload
    ) {
        let context = PluginClipboardActionContext(dismissHistoryWindow: { [weak self] then in
            guard let self else {
                then()
                return
            }
            // Dismiss without restoring focus so the wall's slide-out doesn't
            // fight the activation of whatever the plugin presents next.
            self.dismiss(restoreFocus: false) {
                Task { @MainActor in then() }
            }
        })
        Task { @MainActor in
            await PluginRegistry.shared.performClipboardAction(
                pluginID: owner, actionID: action.id, payload: payload, context: context
            )
        }
    }

    /// "Reveal in Finder" from a file card's context menu. Prefers each entry's
    /// original path; falls back to the stored copy when the original is gone.
    /// Activating Finder resigns the wall's key status and dismisses it, which
    /// is fine — the user is leaving for Finder anyway.
    private func revealInFinder(_ entry: ClipboardHistoryEntry) {
        Task {
            guard let materialization =
                await state.presentation.materialization(
                    for: entry.id,
                    purpose: .hostAction,
                    usesCache: false
                )
            else {
                presentActionFailure()
                return
            }
            let urls = materialization.fileURLs
            guard !urls.isEmpty else {
                ClipboardHistoryActionFailurePresenter.present(
                    .operationUnavailable
                )
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    /// "Ignore Source App" from a card's context menu: future captures from
    /// that app are skipped by the v2 monitor. Existing history stays intact.
    private func ignoreSource(_ entry: ClipboardHistoryEntry) {
        guard let bundleID = entry.source.bundleIdentifier else { return }
        ClipboardPreferences.addExcludedBundleID(bundleID)
        Task {
            await clipboardHistoryLifecycle?
                .refreshMonitoringConfiguration()
        }
        let name = entry.source.displayName ?? bundleID
        ToastPresenter.shared.show(.success(L(.clipboardToastSourceIgnored, name)))
    }

    // MARK: - Tag dialog

    /// Commit the in-wall tag dialog through the module-owned definition
    /// operations. The dialog closes only after the module accepts the change.
    private func commitTagDialog() {
        guard let dialog = state.tagDialog else { return }
        let name = state.tagDialogText
        if case .create = dialog,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }
        if case .rename = dialog,
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return
        }
        Task {
            let succeeded: Bool
            switch dialog {
            case .create(let entryID):
                succeeded =
                    await state.presentation.createTagDefinition(
                        named: name,
                        assigningTo: entryID
                    )
            case .rename(let tagID):
                succeeded =
                    await state.presentation.renameTagDefinition(
                        id: tagID,
                        to: name
                    )
            case .confirmDelete(let tagID):
                succeeded =
                    await state.presentation.deleteTagDefinition(
                        id: tagID
                    )
            }
            guard succeeded else {
                presentActionFailure()
                return
            }
            cancelTagDialog()
        }
    }

    private func cancelTagDialog() {
        state.tagDialog = nil
        state.tagDialogText = ""
    }

    // MARK: - Quick Look (space)

    /// Space: text-bearing kinds open the floating text panel; image/screenshot/
    /// file open the Quick Look panel; color has no preview (the card already
    /// shows the value). Pressing Space again closes whichever is up.
    private func togglePreview() {
        guard let entry = state.selectedItem else { return }
        if ClipboardTextWindow.shared.isPreviewVisible
            || ClipboardQuickLookWindow.shared.isVisible
        {
            closePreviews()
            return
        }
        presentPreview(for: entry)
    }

    /// Keep an open preview in step with the keyboard selection (Finder Quick
    /// Look behavior): the text panel follows text-bearing kinds, the Quick Look
    /// panel follows file-backed ones, and each closes when the selection moves
    /// to a kind it can't show.
    private func syncPreview() {
        guard ClipboardTextWindow.shared.isPreviewVisible
                || ClipboardQuickLookWindow.shared.isVisible,
            let entry = state.selectedItem
        else {
            return
        }
        presentPreview(for: entry)
    }

    /// Drops both floating previews. Used wherever the selection or the visible
    /// item set is about to change under them (delete, tab switch, search).
    private func closePreviews() {
        previewTask?.cancel()
        previewTask = nil
        if ClipboardTextWindow.shared.isPreviewVisible { ClipboardTextWindow.shared.close() }
        ClipboardQuickLookWindow.shared.close()
    }

    private func presentPreview(for entry: ClipboardHistoryEntry) {
        previewTask?.cancel()
        previewTask = Task {
            guard let materialization =
                await state.presentation.materialization(
                    for: entry.id,
                    purpose: .fullPreview
                ),
                !Task.isCancelled,
                state.selectedItem?.id == entry.id
            else {
                if state.presentation.actionFailure != nil {
                    presentActionFailure()
                }
                closePreviews()
                return
            }
            if let text = materialization.exactTexts?.joined(
                separator: "\n"
            ), !text.isEmpty {
                ClipboardQuickLookWindow.shared.close()
                ClipboardTextWindow.shared.showPreview(
                    entry: entry,
                    text: text
                )
            } else if let data = materialization.firstBitmapData {
                ClipboardTextWindow.shared.close()
                ClipboardQuickLookWindow.shared.show(bitmapData: data)
            } else if let url = materialization.fileURLs.first {
                ClipboardTextWindow.shared.close()
                ClipboardQuickLookWindow.shared.show(url: url)
            } else {
                closePreviews()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
    }
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while the floating text panel is up — the text editor takes
        // key status while the wall stays open behind it. (The Quick Look panel
        // never takes key, so it can't be the reason the wall resigned.)
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
