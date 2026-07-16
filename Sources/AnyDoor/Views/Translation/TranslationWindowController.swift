import AppKit
import PluginInterface
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
    /// While active, the Spotlight-style dismissal paths (resign-key + outside-click)
    /// are inhibited. Used to ride out a system credential prompt that steals key
    /// focus mid-translate (see `runKeychainSensitive`).
    private var autoDismissSuspension = AutoDismissSuspension()
    private var autoDismissRearmTask: Task<Void, Never>?
    private var autoDismissSuspended: Bool { autoDismissSuspension.isActive }

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
        // `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive;
        // setting both throws NSInternalInconsistencyException. Match the other
        // Spotlight-style summoned panels (command palette, app picker) and let
        // the panel join all spaces so the global hotkey can surface it anywhere.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 420, height: 420)

        super.init(window: panel)
        panel.delegate = self

        // Building an LLM provider reads its API key from the Keychain, which can
        // raise a blocking system credential dialog; Apple's card can raise a
        // language-pack download sheet. Both steal key focus (and the click that
        // dismisses them lands in another process's window), which would trip the
        // panel's auto-dismiss. Bracket that work so the panel survives.
        let coordinator = TranslationCoordinator.shared
        coordinator.withKeychainPromptGuard = { [weak self] work in
            guard let self else { work(); return }
            self.runKeychainSensitive(work)
        }
        coordinator.onBeginSystemSheet = { [weak self] in self?.suspendAutoDismiss() }
        coordinator.onEndSystemSheet = { [weak self] in self?.reclaimFocusAndRearm() }
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
        autoDismissRearmTask?.cancel()
        autoDismissRearmTask = nil
        autoDismissSuspension.reset()
        removeKeyMonitor()
        removeDismissMonitors()
        window?.orderOut(nil)
    }

    /// Run keychain-sensitive work (which may block on a system credential
    /// prompt) with auto-dismiss inhibited, then reclaim key focus and re-arm
    /// dismissal only after the prompt's queued focus-loss events have flushed —
    /// otherwise the resign-key / outside-click that the prompt generates would
    /// close the panel out from under the user.
    private func runKeychainSensitive(_ work: () -> Void) {
        suspendAutoDismiss()
        work()
        reclaimFocusAndRearm()
    }

    /// Inhibit the Spotlight-style dismissal paths while a system prompt/sheet
    /// holds focus. Paired with `reclaimFocusAndRearm`.
    private func suspendAutoDismiss() {
        autoDismissRearmTask?.cancel()
        autoDismissRearmTask = nil
        if autoDismissSuspension.begin() {
            removeDismissMonitors()
        }
    }

    /// Take key focus back from a system prompt/sheet (the click that dismissed
    /// it landed in another process), then re-arm dismissal only after the queued
    /// resign-key / outside-click events have flushed.
    private func reclaimFocusAndRearm() {
        guard autoDismissSuspension.end() == .readyToRearm else { return }

        if window?.isVisible == true {
            window?.makeKeyAndOrderFront(nil)
        }
        autoDismissRearmTask?.cancel()
        autoDismissRearmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.autoDismissRearmTask = nil
            if !self.isPinned, self.window?.isVisible == true {
                self.installDismissMonitors()
            }
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned
        if pinned {
            // Pinned windows stay put: drop the Spotlight dismissal monitors.
            removeDismissMonitors()
        } else if window?.isVisible == true, !autoDismissSuspended {
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
        // input field can be cleared without losing the window. Also held off
        // while a system prompt/sheet is being ridden out, so a buffered Esc that
        // dismissed that prompt can't leak through and close the panel.
        if keyCode == 53, !isPinned, !autoDismissSuspended {
            close()
            return true
        }
        return false
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        guard !autoDismissSuspended else { return }
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            MainThreadIsolation.run {
                guard !self.autoDismissSuspended else { return }
                if !self.isInsideOwnWindows(event.window) { self.close() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run {
                guard let self, !self.autoDismissSuspended else { return }
                self.close()
            }
        }
        mouseMonitors = [local, global].compactMap { $0 }
    }

    private func removeDismissMonitors() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
    }

    /// Whether a mouse-down landed in the panel or one of its auxiliary windows.
    /// SwiftUI Menu/Picker dropdowns and popovers open in separate child/attached
    /// windows of the panel, so clicking one must NOT dismiss the panel — only a
    /// genuine click in an unrelated window should. A nil window (events outside
    /// any app window) is handled by the global monitor, so treat it as inside
    /// here to avoid double-dismissing.
    private func isInsideOwnWindows(_ candidate: NSWindow?) -> Bool {
        guard let candidate else { return true }
        guard let window else { return false }
        if candidate === window { return true }
        // Child windows (e.g. SwiftUI Picker dropdowns) and attached sheets/popovers.
        if window.childWindows?.contains(candidate) == true { return true }
        if candidate.parent === window { return true }
        if candidate.attachedSheet === window || window.attachedSheet === candidate { return true }
        return false
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }

    /// Unpinned windows dismiss when focus leaves (Spotlight UX); pinned ones
    /// stay visible in the background.
    func windowDidResignKey(_ notification: Notification) {
        guard !isPinned, !autoDismissSuspended else { return }
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
