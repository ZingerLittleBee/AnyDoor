import AppKit
import SwiftUI

/// Owns a single borderless toast window shown at the bottom-center of the screen.
/// `show(_:)` is the only public entry point; the toast auto-dismisses after ~1s.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private let panel: ToastPanel
    private let hostingController: NSHostingController<ToastView>
    private var dismissTask: Task<Void, Never>?

    private init() {
        let controller = NSHostingController(rootView: ToastView(style: .success("")))
        controller.sizingOptions = [.preferredContentSize]
        self.hostingController = controller

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        self.panel = panel
    }

    /// Show a toast. A new call replaces the current toast in place and resets the timer.
    func show(_ style: ToastStyle) {
        dismissTask?.cancel()

        hostingController.rootView = ToastView(style: style)
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        if size.width > 0 && size.height > 0 {
            panel.setContentSize(size)
        }
        positionPanel(size: panel.frame.size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // hold 1.0s
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            panel.orderOut(nil)
        }
    }

    /// Bottom-center of the screen containing the mouse cursor (fallback: main screen),
    /// clear of the Dock.
    private func positionPanel(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let originX = visible.midX - size.width / 2
        let originY = visible.minY + 120
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

/// Borderless panel that never takes focus — the toast is purely informational.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
