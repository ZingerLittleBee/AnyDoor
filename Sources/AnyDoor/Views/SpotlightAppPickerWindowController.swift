import AppKit
import SwiftUI

@MainActor
final class SpotlightAppPickerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SpotlightAppPickerWindowController()

    private var onSelect: ((InstalledApp) -> Void)?
    private var state: SpotlightPickerState?
    private var keyMonitor: Any?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .fullSizeContentView],
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
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(
        apps: [InstalledApp],
        excluded: Set<String>,
        onSelect: @escaping (InstalledApp) -> Void
    ) {
        self.onSelect = onSelect
        let pickerState = SpotlightPickerState(apps: apps, excluded: excluded)
        self.state = pickerState

        let view = SpotlightAppPicker(
            state: pickerState,
            onSelect: { [weak self] app in
                self?.commit(app)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host

        installKeyMonitor()

        positionAtTopCenter()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionAtTopCenter() {
        guard let window, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        // Top inset of ~22% of visible height matches macOS Spotlight feel.
        let topInset = visible.height * 0.22
        let y = visible.maxY - size.height - topInset
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        // Local monitor: intercepts key events for THIS app before they reach
        // the focused responder. Returning nil swallows the event; returning
        // the event lets it propagate (so typing into the search field works).
        // We only pass the Sendable `keyCode` across the MainActor boundary —
        // NSEvent itself isn't Sendable under Swift 6 strict concurrency.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated {
                self?.handle(keyCode: keyCode) ?? false
            }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Returns true if the key was consumed.
    private func handle(keyCode: UInt16) -> Bool {
        guard let window, window.isVisible, window.isKeyWindow else { return false }
        guard let state else { return false }

        switch keyCode {
        case 125: // arrow down
            state.moveDown()
            return true
        case 126: // arrow up
            state.moveUp()
            return true
        case 36, 76: // return, numeric enter
            if let app = state.commitSelection() {
                commit(app)
            }
            return true
        case 53: // escape
            cancel()
            return true
        default:
            return false
        }
    }

    private func commit(_ app: InstalledApp) {
        let callback = onSelect
        onSelect = nil
        close()
        callback?(app)
    }

    private func cancel() {
        onSelect = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        state = nil
        onSelect = nil
    }

    /// Mirror Spotlight UX: close when focus moves away.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
