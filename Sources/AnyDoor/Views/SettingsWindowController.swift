import AppKit
import ClipboardHistory
import PluginInterface
import PluginSupport
import SwiftData
import SwiftUI

/// Hosts the Settings window as a manually managed NSWindow — the same window
/// type as the Image Conversion workspace (standard chrome, transparent
/// titlebar, full-height sidebar wrapping the traffic lights) — but fixed-size
/// and without a collapsible sidebar. Replacing the SwiftUI `Settings` scene
/// lets AppKit code open the window directly, without the `\.openSettings`
/// capture dance (and the invisible anchor window it required).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    /// Full window size, title-bar region included (`.fullSizeContentView`).
    private static let contentSize = NSSize(width: 680, height: 512)
    private static let frameName = "settings.windowFrame"

    /// Handed over by `AppDelegate` at launch. Do NOT read it from
    /// `NSApp.delegate`: under `@NSApplicationDelegateAdaptor` that is
    /// SwiftUI's own delegate wrapper, and the cast to `AppDelegate` fails —
    /// which would leave the window mounting nothing (a bare empty shell).
    private static var modelContainer: ModelContainer?
    private static var clipboardHistoryModule: ClipboardHistoryModule?
    private static var clipboardHistoryLifecycle: ClipboardHistoryLifecycle?

    static func bootstrap(
        modelContainer: ModelContainer,
        clipboardHistoryModule: ClipboardHistoryModule,
        clipboardHistoryLifecycle: ClipboardHistoryLifecycle
    ) {
        self.modelContainer = modelContainer
        self.clipboardHistoryModule = clipboardHistoryModule
        self.clipboardHistoryLifecycle = clipboardHistoryLifecycle
    }

    private var keyMonitor: Any?

    private init() {
        // Fixed-size utility window: the mask carries no .miniaturizable /
        // .resizable, so the yellow/green buttons render disabled-gray like a
        // classic Settings window. `.fullSizeContentView` lets the sidebar run
        // to the window top, like the Image Conversion window.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Same chrome as the Image Conversion window: the titlebar separator
        // would read as a stray hairline, and hiding the SwiftUI toolbar fill
        // is not enough on a manually managed window — the titlebar's own
        // material still paints a strip over the detail column.
        window.titlebarSeparatorStyle = .none
        window.titlebarAppearsTransparent = true
        // Hide the title text (the AppKit half of the old scene's
        // `.windowStyle(.hiddenTitleBar)`). Note this alone does NOT make the
        // sidebar wrap the traffic lights — that treatment needs a toolbar,
        // bridged from SwiftUI in `mountContentIfNeeded`. Do NOT attach a
        // bare AppKit NSToolbar for it instead: unlike the bridged one, its
        // empty band swallows every click in the top ~52pt, making controls
        // placed there dead.
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isRestorable = false

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show() {
        guard let window else { return }
        window.title = L(.panelFooterSettings)
        mountContentIfNeeded()
        restorePosition()
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
        guard let window,
              window.contentView == nil || !(window.contentView is NSHostingView<SettingsRoot>) else { return }
        guard let container = Self.modelContainer,
            let module = Self.clipboardHistoryModule,
            let lifecycle = Self.clipboardHistoryLifecycle
        else {
            assertionFailure("SettingsWindowController.bootstrap was not called before show()")
            return
        }
        let host = NSHostingView(
            rootView: SettingsRoot(
                container: container,
                clipboardHistoryModule: module,
                clipboardHistoryLifecycle: lifecycle
            )
        )
        // Let SwiftUI install the (item-less) NavigationSplitView toolbar —
        // its presence is what grants the full-height sidebar treatment that
        // wraps the traffic lights, same as the Image Conversion window.
        host.sceneBridgingOptions = [.toolbars]
        host.frame = window.contentLayoutRect
        host.autoresizingMask = [.width, .height]
        window.contentView = host
    }

    /// The window's size is fixed; only its position is remembered.
    private func restorePosition() {
        guard let window else { return }
        if let saved = UserDefaults.standard.string(forKey: Self.frameName) {
            let origin = NSRectFromString(saved).origin
            let rect = NSRect(origin: origin, size: window.frame.size)
            if let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(rect) }) {
                window.setFrame(window.constrainFrameRect(rect, to: screen), display: false)
                return
            }
        }
        window.center()
    }

    private func savePosition() {
        guard let window, window.isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameName)
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
        // Esc closes, unless a focused control should consume it first (a text
        // field cancelling its edit, a list clearing its selection).
        if event.keyCode == 53 {
            if FocusedControlKeyPolicy.shouldDefer(
                keyCode: Int(event.keyCode),
                firstResponder: window?.firstResponder
            ) {
                return false
            }
            close()
            return true
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.keyCode == 13 {
            close()
            return true
        }
        return false
    }

    func windowDidMove(_ notification: Notification) { savePosition() }
    // The traffic-light close path bypasses our `close()` override, so the
    // cleanup lives in the delegate callback both paths reach.
    func windowWillClose(_ notification: Notification) {
        savePosition()
        removeKeyMonitor()
    }
}

/// Root view for the hosted Settings window. Reading `effectiveLocale` inside
/// `body` keeps the locale environment live when the user switches the app
/// language (a static `NSHostingView` rootView would otherwise freeze the
/// value captured at mount time).
private struct SettingsRoot: View {
    let container: ModelContainer
    let clipboardHistoryModule: ClipboardHistoryModule
    let clipboardHistoryLifecycle: ClipboardHistoryLifecycle

    var body: some View {
        let localization = LocalizationManager.shared
        SettingsView(
            clipboardHistoryModule: clipboardHistoryModule,
            clipboardHistoryLifecycle: clipboardHistoryLifecycle
        )
            .modelContainer(container)
            .environment(localization)
            .environment(\.locale, localization.effectiveLocale)
    }
}
