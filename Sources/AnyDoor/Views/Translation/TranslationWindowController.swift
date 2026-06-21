import AppKit
import SwiftUI

/// Spotlight-style floating panel hosting the translation UI. The panel can
/// become key (so the input TextEditor takes keystrokes) and remembers its frame
/// under `windowFrameKey`. While unpinned it dismisses on Esc or an outside
/// click (Spotlight UX); pinning removes those monitors so the window stays put
/// and behaves like a normal floating utility window.
@MainActor
final class TranslationWindowController: NSWindowController, NSWindowDelegate {
    static let shared = TranslationWindowController()

    static let windowFrameKey = "translation.windowFrame"

    private(set) var isPinned: Bool = false
    private var keyMonitor: Any?
    private var mouseMonitors: [Any] = []

    private init() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .fullSizeContentView, .resizable, .closable],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 420)
        panel.setFrameAutosaveName("")

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func toggle() {
        if window?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let window else { return }
        mountContentIfNeeded()
        restoreFrame()

        // Activate first so a `.accessory` app summoned from a global hotkey can
        // actually make the panel key (see CommandPaletteWindowController for the
        // full rationale on the focus oscillation otherwise).
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        installKeyMonitor()
        if !isPinned { installDismissMonitors() }
    }

    func showPrefilled(_ text: String) {
        show()
        TranslationCoordinator.shared.prefill(text, autoTranslate: true)
    }

    override func close() {
        saveFrame()
        removeKeyMonitor()
        removeDismissMonitors()
        window?.orderOut(nil)
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            // Pinned windows stay put: drop the Spotlight dismissal monitors.
            removeDismissMonitors()
        } else if window?.isVisible == true {
            installDismissMonitors()
        }
    }

    private func mountContentIfNeeded() {
        guard let window, window.contentView == nil || !(window.contentView is NSHostingView<TranslationView>) else { return }
        let view = TranslationView(controller: self)
        let host = NSHostingView(rootView: view)
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    // MARK: - Frame persistence

    private func restoreFrame() {
        guard let window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.windowFrameKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 0, rect.height > 0, visibleOnAnyScreen(rect) {
                window.setFrame(rect, display: false)
                return
            }
        }
        positionAtCenter()
    }

    private func saveFrame() {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameKey)
    }

    private func visibleOnAnyScreen(_ rect: NSRect) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
    }

    private func positionAtCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - visible.height * 0.15
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Monitors

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainThreadIsolation.run { self?.handle(keyCode: keyCode) ?? false }
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
        // Esc dismisses only when unpinned; a pinned window ignores it so the
        // input field can be cleared without losing the window.
        if keyCode == 53, !isPinned {
            close()
            return true
        }
        return false
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            MainThreadIsolation.run {
                if event.window !== self.window { self.close() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.close() }
        }
        mouseMonitors = [local, global].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    /// Unpinned windows dismiss when focus leaves (Spotlight UX); pinned ones
    /// stay visible in the background.
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned else { return }
        close()
    }
}

/// Titled panels can become key already, but a panel built to behave like a
/// utility/floating window needs `canBecomeKey` forced on so the embedded
/// TextEditor can take keystrokes even when the app is `.accessory`.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
