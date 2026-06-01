import AppKit
import QuartzCore
import QuickLookUI
import SwiftUI

/// Bottom, full-width overlay that hosts the clipboard card wall. Summoned by
/// the clipboard-wall hotkey (via ClipboardWallProvider) or the panel row.
/// Mirrors CommandPaletteWindowController's activation/key-monitor pattern.
@MainActor
final class ClipboardWallWindowController: NSWindowController, NSWindowDelegate, QLPreviewPanelDataSource {
    static let shared = ClipboardWallWindowController()

    /// Set by AppDelegate so paste-from-history can suppress the self-write.
    weak var watcher: ClipboardWatcher?

    private let state = ClipboardWallState()
    /// Built once and reused across opens. Rebuilding the whole SwiftUI tree on
    /// every show realizes all cards as the slide-in starts, which stutters the
    /// animation; reusing it means show just moves already-rendered content.
    private var hostingView: NSHostingView<ClipboardWallView>?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var globalMouseMonitor: Any?
    private var changeObserver: (any NSObjectProtocol)?
    private var refreshTimer: Timer?
    /// Accumulated scroll delta; selection advances each time it crosses a step.
    private var scrollAccum: CGFloat = 0
    private static let scrollStep: CGFloat = 40
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
        // Refresh live when the history changes (e.g. a new copy is captured)
        // so the open wall doesn't require a tab switch to show it. Retain the
        // token so the block-based observer stays registered.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .clipboardHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible() }
        }
    }

    /// Re-query and update the open wall in place; ignored when hidden.
    private func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        loadTimelineNow()
    }

    /// While the wall is open, poll the store as a guaranteed backstop to the
    /// change notification — new captures land within one tick regardless.
    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        guard !isAnimating else { return }
        if window?.isVisible == true { dismiss(restoreFocus: true) } else { show() }
    }

    private func show() {
        // Populate synchronously so the first render already has data; an async
        // reload would land mid-animation and the heavy first render (image
        // decoding) would stutter the slide-in.
        loadTimelineNow()
        // Force the watcher to capture immediately so content copied just before
        // opening shows up now, rather than after the next ~0.5s poll tick.
        Task { [weak self] in
            await self?.watcher?.poll()
            self?.loadTimelineNow()
        }
        buildHostingViewIfNeeded()
        installMonitors()

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
            MainActor.assumeIsolated { self?.isAnimating = false }
        })

        startRefreshTimer()

        // Enforce retention off the critical path, then refresh if it changed.
        Task {
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false)
            loadTimelineNow()
        }
    }

    /// Slide the panel down off-screen, then close it. When `restoreFocus` is
    /// true the previously frontmost app is reactivated first (Esc / paste);
    /// for a click elsewhere it is false, since that click already moved focus.
    /// `completion` runs after the window has ordered out, so paste can post ⌘V
    /// once focus has returned. No-op if already hidden or mid-animation.
    private func dismiss(restoreFocus: Bool, completion: (@Sendable () -> Void)? = nil) {
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
            MainActor.assumeIsolated {
                self?.isAnimating = false
                self?.close()
                completion?()
            }
        })
    }

    /// Build and install the SwiftUI host once; later shows reuse it.
    private func buildHostingViewIfNeeded() {
        guard hostingView == nil else { return }
        let view = ClipboardWallView(
            state: state,
            historyDirectory: historyDirectory,
            onSelect: { [weak self] item, plain in self?.paste(item, plain: plain) },
            onToggleFavorite: { [weak self] item in
                Task { await ClipboardHistoryStore.shared.toggleFavorite(item); self?.reloadItems() }
            },
            onFilterChange: { [weak self] in self?.reloadItems() }
        )
        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        hostingView = host
    }

    /// Synchronously query the store and push the result into state. The fetch
    /// runs on the main actor, so the wall renders with data immediately. Skips
    /// the update when the item set is unchanged so the periodic refresh doesn't
    /// churn the view or reset the selection.
    private func loadTimelineNow() {
        let fresh = ClipboardHistoryStore.shared.timeline(category: state.category, query: state.query)
        guard fresh.map(\.id) != state.items.map(\.id) else { return }
        state.setItems(fresh)
    }

    /// Prune (async) then re-query; used for filter changes and after edits,
    /// where a brief delay before refresh is fine.
    private func reloadItems() {
        Task {
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false)
            loadTimelineNow()
        }
    }

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        // Translate the scroll wheel / trackpad swipe into card navigation; the
        // horizontal ScrollView otherwise ignores a plain vertical mouse wheel.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }
        // A global mouse-down fires only for clicks NOT delivered to our app —
        // i.e. anywhere outside the wall — so any such click dismisses it.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
                self.dismiss(restoreFocus: false)
            }
        }
    }

    private func removeMonitors() {
        for monitor in [keyMonitor, scrollMonitor, globalMouseMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        scrollMonitor = nil
        globalMouseMonitor = nil
        scrollAccum = 0
    }

    /// Step the selection as scroll delta accumulates past `scrollStep`. Uses
    /// whichever axis dominates so both a vertical mouse wheel and a horizontal
    /// trackpad swipe flip through the cards. Negative delta advances right.
    private func handleScroll(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        // Ignore trackpad inertia so flicking doesn't keep advancing after the
        // fingers lift; only act on the user's active scroll.
        guard event.momentumPhase == [] else { return true }
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollAccum += delta
        while scrollAccum <= -Self.scrollStep { state.moveRight(); scrollAccum += Self.scrollStep }
        while scrollAccum >= Self.scrollStep { state.moveLeft(); scrollAccum -= Self.scrollStep }
        return true
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        // While the search field is first responder, let typing through (but
        // still honor Esc / arrows when the field is empty is overkill — keep
        // it simple: Esc always closes, arrows always navigate).
        switch event.keyCode {
        case 123: state.moveLeft(); return true          // ←
        case 124: state.moveRight(); return true         // →
        case 36, 76:                                     // ↵ / numpad enter
            if let item = state.selectedItem {
                paste(item, plain: event.modifierFlags.contains(.option))
            }
            return true
        case 49:                                         // space → Quick Look
            toggleQuickLook(); return true
        case 51:                                         // ⌫ → delete selected
            if let item = state.selectedItem {
                Task { await ClipboardHistoryStore.shared.delete(item); self.reloadItems() }
            }
            return true
        case 53: dismiss(restoreFocus: true); return true // esc
        default: return false
        }
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

    // MARK: - Quick Look (space)
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
        MainActor.assumeIsolated { previewURL == nil ? 0 : 1 }
    }
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewURL as NSURL? }
    }

    func windowWillClose(_ notification: Notification) {
        removeMonitors()
        stopRefreshTimer()
    }
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while Quick Look is the key window.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
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
