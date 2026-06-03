import AppKit
import SwiftUI

@MainActor
final class HostsEditorWindowController: NSWindowController, NSWindowDelegate {
    static let shared = HostsEditorWindowController()

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Hosts"
        panel.isReleasedWhenClosed = false
        // A normal-level window (not floating) that does not hide when the app
        // deactivates; RegularWindowCoordinator keeps it reachable via Dock /
        // Cmd-Tab while it is open.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        let view = HostsEditorView(manager: HostsManager.shared)
        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        HostsManager.shared.refresh()
        if let window { RegularWindowCoordinator.shared.track(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }
}
