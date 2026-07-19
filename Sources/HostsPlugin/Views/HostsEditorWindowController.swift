import AppKit
import PluginInterface
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
        panel.isRestorable = false
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

    func show(manager: HostsManager = .shared) {
        let view = HostsEditorView(manager: manager)
        let host = NSHostingView(rootView: view)
        host.frame = window?.contentLayoutRect ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        manager.refresh()
        if let window { PluginHost.trackRegularWindow(window) }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    /// Uninstall: tear the editor down so no plugin surface survives.
    /// `close()` (not `orderOut`) so the host's window tracking sees a real
    /// close and can revert the activation policy; dropping the content view
    /// releases the SwiftUI tree.
    func closeForUninstall() {
        window?.close()
        window?.contentView = nil
    }
}
