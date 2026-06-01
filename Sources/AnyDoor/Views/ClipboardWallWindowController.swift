import AppKit
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
    private var previewURL: URL?

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
        if window?.isVisible == true { close() } else { show() }
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
        positionAtBottom()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Re-query the store using current category/search and push into state.
    private func reloadItems() {
        Task {
            await ClipboardHistoryStore.shared.pruneExpiredAndOverflow(force: false)
            state.setItems(ClipboardHistoryStore.shared.timeline(category: state.category, query: state.query))
        }
    }

    private func positionAtBottom() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height: CGFloat = 220
        window.setFrame(NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: height), display: true)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
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
        case 53: close(); return true                    // esc
        default: return false
        }
    }

    private func paste(_ item: ClipboardHistoryItem, plain: Bool) {
        if !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) {
            ToastPresenter.shared.show(.failure(L(.clipboardToastFileMissing)))
            return
        }
        close()
        let pb = NSPasteboard.general
        ClipboardPasteService.writePayload(for: item, asPlainText: plain, to: pb, historyDirectory: historyDirectory)
        watcher?.noteSelfWrite(changeCount: pb.changeCount)
        if !ClipboardPreferences.copyOnly {
            // Defer so focus returns to the prior app before ⌘V is posted.
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
        close()
    }
}
