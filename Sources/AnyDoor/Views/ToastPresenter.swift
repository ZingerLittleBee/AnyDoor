import AppKit
import SwiftUI

/// Owns a single borderless toast window shown at the bottom-center of the screen.
/// `show(_:)` is the only public entry point; the toast auto-dismisses after ~1s.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private let panel: ToastPanel
    private let containerView: NSView
    private let hostingView: NSHostingView<ToastView>
    private var dismissTask: Task<Void, Never>?

    private init() {
        let initialView = ToastView(style: .success(""))
        let initialSize = Self.fittingSize(for: initialView, fallback: NSSize(width: 200, height: 44))
        let hostingView = NSHostingView(rootView: initialView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]
        self.hostingView = hostingView

        let containerView = NSView(frame: NSRect(origin: .zero, size: initialSize))
        containerView.addSubview(hostingView)
        self.containerView = containerView

        let panel = ToastPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
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
        panel.contentView = containerView
        self.panel = panel
    }

    /// Show a toast. A new call replaces the current toast in place and resets the timer.
    /// `duration` is how long the pill is held before it fades (default ~1s).
    func show(_ style: ToastStyle, duration: TimeInterval = 1.0) {
        dismissTask?.cancel()

        let toastView = ToastView(style: style)
        hostingView.rootView = toastView
        resizePanel(to: Self.fittingSize(for: toastView, fallback: panel.frame.size))
        positionPanel(size: panel.frame.size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            Task { @MainActor in
                panel.orderOut(nil)
            }
        }
    }

    private func resizePanel(to size: NSSize) {
        guard size.width > 0 && size.height > 0 else { return }
        panel.setContentSize(size)
        containerView.frame = NSRect(origin: .zero, size: size)
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    private static func fittingSize(for rootView: ToastView, fallback: NSSize) -> NSSize {
        let measuringView = NSHostingView(rootView: rootView)
        measuringView.sizingOptions = .intrinsicContentSize
        measuringView.layoutSubtreeIfNeeded()
        let fitting = measuringView.fittingSize
        if fitting.width > 0 && fitting.height > 0 { return fitting }
        return fallback
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
