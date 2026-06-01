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
    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var previewURL: URL?

    /// Guards against re-entrant show/dismiss while the slide animation runs.
    private var isAnimating = false
    private static let panelHeight: CGFloat = 285
    private static let animationDuration: TimeInterval = 0.22

    private var historyDirectory: URL { ClipboardHistoryStore.defaultHistoryDirectory() }

    private init() {
        let panel = NSPanel(
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
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() {
        guard !isAnimating else { return }
        if window?.isVisible == true { dismiss() } else { show() }
    }

    private func show() {
        reloadItems()
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

        installKeyMonitor()

        guard let window, let screen = NSScreen.main else { return }
        // Anchor to the screen's physical bottom edge (not visibleFrame, which
        // sits above the Dock) so the panel is flush with no gap underneath.
        let bounds = screen.frame
        let onScreen = NSRect(x: bounds.minX, y: bounds.minY,
                              width: bounds.width, height: Self.panelHeight)
        // A .nonactivatingPanel becomes key WITHOUT activating AnyDoor, so the
        // previously focused app keeps focus — paste returns there, and clicking
        // it makes us resign key (windowDidResignKey dismisses). Deliberately do
        // NOT call NSApp.activate here, which would steal focus from that app.
        window.setFrame(onScreen.offsetBy(dx: 0, dy: -Self.panelHeight), display: false)
        window.makeKeyAndOrderFront(nil)
        isAnimating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.animationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .linear)
            window.animator().setFrame(onScreen, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.isAnimating = false }
        })
    }

    /// Slide the panel down off-screen, then close it. `completion` runs after
    /// the window has ordered out (so paste can post ⌘V once focus has returned
    /// to the prior app). No-op if already hidden or mid-animation.
    private func dismiss(completion: (@Sendable () -> Void)? = nil) {
        guard !isAnimating, let window, window.isVisible, let screen = NSScreen.main else {
            completion?()
            return
        }
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

    /// Re-query the store using current category/search and push into state.
    private func reloadItems() {
        Task {
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false)
            state.setItems(ClipboardHistoryStore.shared.timeline(category: state.category, query: state.query))
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
        // A global mouse-down fires only for clicks NOT delivered to our app —
        // i.e. anywhere outside the wall — so any such click dismisses it. This
        // is more reliable than windowDidResignKey for a non-activating panel.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
                self.dismiss()
            }
        }
    }

    private func removeKeyMonitor() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor); self.globalMouseMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
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
        case 53: dismiss(); return true                  // esc
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
        // Slide out first; once the panel has ordered out, key returns to the
        // prior app, so the synthesized ⌘V lands there rather than on our panel.
        dismiss { [copyOnly = ClipboardPreferences.copyOnly] in
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

    func windowWillClose(_ notification: Notification) { removeKeyMonitor() }
    func windowDidResignKey(_ notification: Notification) {
        // Don't close while Quick Look is the key window.
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { return }
        // Ignore the resign that the slide-out animation itself triggers.
        guard !isAnimating else { return }
        dismiss()
    }
}
