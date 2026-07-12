import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ImageConversionWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ImageConversionWindowController()
    static let windowFrameKey = "imageConversion.windowFrame"
    /// Tracks whether the lazy singleton exists so import reconciliation can
    /// reload a live view model without instantiating the window.
    private static var sharedExists = false

    private let viewModel = ImageConversionViewModel()
    private var keyMonitor: Any?

    /// A backup import rewrote the conversion preferences; push them into the
    /// live view model. A no-op when the window was never created.
    static func reconcilePreferencesAfterImport() {
        guard sharedExists else { return }
        shared.viewModel.reloadFromDefaults()
    }

    private init() {
        // A standard-chrome workspace window: system title bar, working
        // minimize/zoom, normal level. It yields to other apps and relies on
        // RegularWindowCoordinator (see `show()`) to stay reachable under the
        // accessory activation policy. `.fullSizeContentView` lets the
        // NavigationSplitView sidebar run full height — up to the window top,
        // wrapping the traffic lights, like Finder/Notes.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // The detail toolbar background is hidden (the canvas color runs to
        // the window top), so the titlebar separator would read as a stray
        // hairline across the canvas.
        window.titlebarSeparatorStyle = .none
        // Hiding the SwiftUI toolbar fill is not enough on this manually
        // managed window: the titlebar's own material still paints a strip
        // that mismatches the canvas (near-white over gray in light mode).
        // Drop it; the sidebar draws its own full-height surface and the
        // title text is unaffected.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isRestorable = false
        window.minSize = NSSize(width: 960, height: 600)

        super.init(window: window)
        window.delegate = self
        Self.sharedExists = true
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
        // Normal-level window of an accessory app: adopt .regular policy while
        // it is open so it stays reachable (untracked on willClose).
        RegularWindowCoordinator.shared.track(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Drop the initial first responder so no control renders a focus ring
        // when the window appears (keyboard focus returns on first Tab).
        window.makeFirstResponder(nil)
    }

    override func close() {
        // `NSWindow.close()` (not `orderOut`) so willClose fires: cleanup in
        // `windowWillClose` and RegularWindowCoordinator's untracking both
        // depend on it, and the traffic-light path already goes through it.
        window?.close()
    }

    private func mountContentIfNeeded() {
        guard let window, window.contentView == nil || !(window.contentView is NSHostingView<ImageConversionView>) else { return }
        let view = ImageConversionView(model: viewModel)
        let host = NSHostingView(rootView: view)
        // Let SwiftUI install the NavigationSplitView toolbar (the sidebar
        // toggle) onto this manually managed window.
        host.sceneBridgingOptions = [.toolbars]
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
        if Self.shouldDeferToFocusedControl(
            keyCode: Int(event.keyCode),
            firstResponder: window?.firstResponder
        ) {
            return false
        }
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
        if event.keyCode == kVK_ANSI_B {
            viewModel.toggleSidebar()
            return true
        }
        return false
    }

    static func shouldDeferToFocusedControl(
        keyCode: Int,
        firstResponder: NSResponder?
    ) -> Bool {
        guard keyCode == 53 || keyCode == kVK_ANSI_V else { return false }
        return firstResponder is NSTextView
            || firstResponder is NSControl
            || firstResponder is NSCollectionView
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
    func windowDidResize(_ notification: Notification) { saveFrame() }
    // The traffic-light close path bypasses our `close()` override, so the
    // cleanup lives in the delegate callback both paths reach.
    func windowWillClose(_ notification: Notification) {
        saveFrame()
        removeKeyMonitor()
        viewModel.windowDidHide()
    }
}
