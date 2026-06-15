import AppKit
import SwiftUI

/// Floating, non-activating panel that hosts `ShutdownWarningView`. Conforms to
/// `ShutdownWarningPresenting` so `ScheduledShutdownService` can show/update/
/// dismiss it without referencing AppKit directly (and tests can inject a mock).
@MainActor
final class ShutdownWarningWindowController: ShutdownWarningPresenting {
    private var panel: NSPanel?
    private var seconds: Int = 0
    private var onCancel: (@MainActor () -> Void)?

    func present(totalSeconds: Int, onCancel: @escaping @MainActor () -> Void) {
        self.seconds = totalSeconds
        self.onCancel = onCancel
        let panel = ensurePanel()
        render()
        positionCenteredTop(panel)
        panel.orderFrontRegardless()
    }

    func update(secondsRemaining: Int) {
        seconds = secondsRemaining
        render()
    }

    func dismiss() {
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive; both
        // together make macOS 26's `_validateCollectionBehavior` throw. Keep one.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = p
        return p
    }

    private func render() {
        let view = ShutdownWarningView(secondsRemaining: seconds) { [weak self] in
            self?.onCancel?()
        }
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        panel?.setContentSize(size)
        panel?.contentView = host
    }

    private func positionCenteredTop(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
