import AppKit
import SwiftUI

@MainActor
final class ImageConversionWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImageConversionWindowController()
    static let windowFrameKey = "imageConversion.windowFrame"

    private let viewModel = ImageConversionViewModel()
    private var keyMonitor: Any?

    private init() {
        let panel = ImageConversionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isRestorable = false
        panel.minSize = NSSize(width: 440, height: 360)

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
        let urls = await FinderSelectionReader.read()
        viewModel.addFiles(urls)
        show()
    }

    func show() {
        guard let window else { return }
        window.title = L(.imageConversionTitle)
        mountContentIfNeeded()
        restoreFrame()
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    override func close() {
        saveFrame()
        removeKeyMonitor()
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
            let rect = NSRectFromString(saved)
            if rect.width > 0, rect.height > 0, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(rect, display: false)
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
        if event.keyCode == 13, event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
            close()
            return true
        }
        return false
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowWillClose(_ notification: Notification) { removeKeyMonitor() }
}

private final class ImageConversionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
