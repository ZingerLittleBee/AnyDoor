import AppKit
import SwiftUI

@MainActor
final class SpotlightAppPickerWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SpotlightAppPickerWindowController()

    private var onSelect: ((InstalledApp) -> Void)?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
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

        let view = SpotlightAppPicker(
            apps: apps,
            excludedBundleIDs: excluded,
            onSelect: { [weak self] app in
                guard let self else { return }
                self.onSelect?(app)
                self.onSelect = nil
                self.close()
            },
            onCancel: { [weak self] in
                self?.onSelect = nil
                self?.close()
            }
        )

        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host

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

    func windowWillClose(_ notification: Notification) {
        onSelect = nil
    }

    /// Mirror Spotlight UX: close when focus moves away.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}
