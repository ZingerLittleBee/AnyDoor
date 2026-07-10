import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ImageConversionWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImageConversionWindowController()
    static let windowFrameKey = "imageConversion.windowFrame"

    private let viewModel = ImageConversionViewModel()
    private var keyMonitor: Any?

    private init() {
        let panel = ImageConversionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 740),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // Full traffic-light set stays visible: close works (this window has no
        // outside-click dismissal, so the mouse needs an affordance); minimize
        // and zoom are disabled placeholders that keep the familiar spacing.
        // The card ignores the titlebar safe area (see ImageConversionView), so
        // the buttons overlay the card's top-left corner instead of floating in
        // a transparent strip above it.
        panel.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        panel.standardWindowButton(.zoomButton)?.isEnabled = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.minSize = NSSize(width: 960, height: 600)

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Strict toggle: an already-visible window is closed without reading the
    /// Finder selection; otherwise the current Finder selection is echoed into
    /// the basket before the window appears.
    func toggle() async {
        if window?.isVisible == true {
            close()
            return
        }
        if viewModel.isConverting {
            show()
            return
        }
        let urls = await FinderSelectionReader.read()
        viewModel.addFiles(urls)
        show()
    }

    /// Opens the window with a set of basket items preloaded (e.g. echoed from a
    /// clipboard-history entry). Unlike `toggle`, this never reads the Finder
    /// selection and never closes an already-open window — it merges the items
    /// into the current basket and brings the window forward.
    func present(items: [ImageConversionBasketItem]) {
        if !viewModel.isConverting {
            viewModel.add(items)
        }
        show()
    }

    func show() {
        guard let window else { return }
        window.title = L(.imageConversionTitle)
        viewModel.resetSidebarForPresentation()
        mountContentIfNeeded()
        restoreFrame()
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Drop the initial first responder so no control renders a focus ring
        // when the window appears (keyboard focus returns on first Tab).
        window.makeFirstResponder(nil)
        alignTrafficLights()
    }

    /// Vertically centers the traffic lights on the toolbar's first row and
    /// keeps minimize/zoom as disabled placeholders. AppKit pins the buttons to
    /// the standard titlebar position (higher than the row once the card
    /// ignores the titlebar safe area) and re-evaluates zoom's enabled state,
    /// so this runs after every titlebar layout pass (resize, key changes).
    private func alignTrafficLights() {
        guard let window else { return }
        // 10pt toolbar top padding + half the ~24pt first row.
        let centerFromWindowTop: CGFloat = 22
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            let origin = NSPoint(
                x: button.frame.origin.x,
                y: container.bounds.height - centerFromWindowTop - button.frame.height / 2
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
            if kind != .closeButton, button.isEnabled {
                button.isEnabled = false
            }
        }
    }

    override func close() {
        saveFrame()
        removeKeyMonitor()
        viewModel.windowDidHide()
        window?.orderOut(nil)
    }

    private func mountContentIfNeeded() {
        guard let window, window.contentView == nil || !(window.contentView is NSHostingView<ImageConversionView>) else { return }
        let view = ImageConversionView(model: viewModel)
        let host = NSHostingView(rootView: view)
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    private func restoreFrame() {
        guard let window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.windowFrameKey) {
            var rect = NSRectFromString(saved)
            if rect.width > 0,
               rect.height > 0,
               let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) {
                rect.size.width = max(rect.width, window.minSize.width)
                rect.size.height = max(rect.height, window.minSize.height)
                window.setFrame(window.constrainFrameRect(rect, to: screen), display: false)
                return
            }
        }
        window.center()
    }

    private func saveFrame() {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.windowFrameKey)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainThreadIsolation.run { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard window?.isVisible == true, window?.isKeyWindow == true else { return false }
        if event.keyCode == 53 {
            close()
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }
        if event.keyCode == 13 {
            close()
            return true
        }
        if event.keyCode == 9 {
            guard !viewModel.isConverting else { return true }
            pasteFromClipboard()
            return true
        }
        if event.keyCode == kVK_Return {
            viewModel.convert()
            return true
        }
        if event.keyCode == kVK_ANSI_Period {
            viewModel.stopConversion()
            return true
        }
        if event.keyCode == kVK_ANSI_O {
            guard !viewModel.isConverting else { return true }
            viewModel.presentOpenPanel()
            return true
        }
        return false
    }

    /// ⌘V: copied image files enter as file references (like drag & drop); a
    /// copied bitmap enters as a bitmap item. Non-image content is ignored.
    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            viewModel.addFiles(urls)
            return
        }
        if let image = NSImage(pasteboard: pasteboard),
           let png = ClipboardCapture.pngData(from: image) {
            viewModel.addBitmap(png)
        }
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) {
        saveFrame()
        alignTrafficLights()
    }
    func windowDidBecomeKey(_ notification: Notification) { alignTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { alignTrafficLights() }
    // The traffic-light close path bypasses our `close()` override, so the
    // cleanup lives in the delegate callback both paths reach.
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        removeKeyMonitor()
        viewModel.windowDidHide()
    }
}

private final class ImageConversionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
