import SwiftUI
import AppKit

/// Hover-triggered NSWindow popover for the App Shortcuts submenu.
///
/// Owns its own NSWindow so it can position itself relative to the host view's screen frame,
/// regardless of which window the trigger lives in. Uses a `HoverGate` to coordinate
/// show/hide timing across the trigger view and the popover content.
///
/// Lifecycle:
/// - Trigger view installs an `onHover` that arms the gate after 400ms.
/// - Once shown, the popover keeps itself open while either the trigger or popover area
///   contains the cursor; closes after 300ms of cursor leaving both.
@MainActor
final class HoverPopover {
    private let window: NSWindow
    private let hostingController: NSHostingController<AnyView>
    private var hideTask: Task<Void, Never>?

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let controller = NSHostingController(rootView: AnyView(content()))
        // Let the hosting controller resize itself to match SwiftUI's fitting size,
        // so the NSWindow tracks the content's intrinsic dimensions automatically.
        controller.sizingOptions = [.preferredContentSize]
        self.hostingController = controller

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentViewController = controller
        // .nonactivating equivalent: ignoresMouseEvents = false + level floating + don't make key
        self.window = window
    }

    func updateContent<Content: View>(@ViewBuilder content: () -> Content) {
        hostingController.rootView = AnyView(content())
        // Force layout so fittingSize reflects the new content before show() reads it.
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            window.setContentSize(fitting)
        }
    }

    /// Show the popover anchored to the right side of `referenceFrame` (screen coordinates).
    /// If insufficient space on the right, flips to the left.
    func show(anchoredTo referenceFrame: NSRect) {
        hideTask?.cancel()
        hideTask = nil

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        let size = window.frame.size

        let rightX = referenceFrame.maxX + 4
        let leftX = referenceFrame.minX - 4 - size.width
        let originX = (rightX + size.width <= screenFrame.maxX) ? rightX : leftX
        let originY = max(screenFrame.minY,
                          min(referenceFrame.midY - size.height / 2,
                              screenFrame.maxY - size.height))

        window.setFrameOrigin(NSPoint(x: originX, y: originY))
        window.orderFrontRegardless()
    }

    /// Schedule a hide. Cancelled if `keepOpen()` is called within the delay.
    func scheduleHide(after delay: TimeInterval = 0.3) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.window.orderOut(nil)
        }
    }

    func keepOpen() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        window.orderOut(nil)
    }
}

/// Coordinates hover-to-open / leave-to-close timing between a trigger view and a popover.
///
/// Use one instance per popover. The trigger view calls `hoverEnter()`/`hoverExit()`
/// from a `.onHover` modifier; the popover content view does the same from its own
/// `.onHover`. The popover stays open while either reports hovered.
@MainActor
@Observable
final class HoverGate {
    private(set) var isShown = false
    private var triggerHovered = false
    private var popoverHovered = false
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    func triggerHover(_ hovered: Bool) {
        triggerHovered = hovered
        if hovered { scheduleShow() } else { scheduleHide() }
    }

    func popoverHover(_ hovered: Bool) {
        popoverHovered = hovered
        if hovered { showTask?.cancel(); hideTask?.cancel() }
        else { scheduleHide() }
    }

    func showImmediately() {
        showTask?.cancel()
        if !isShown {
            isShown = true
            onShow()
        }
    }

    private func scheduleShow() {
        guard !isShown else { return }
        hideTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000) // 400ms
            guard let self, !Task.isCancelled, self.triggerHovered else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func scheduleHide() {
        guard isShown else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard let self, !Task.isCancelled else { return }
            guard !self.triggerHovered && !self.popoverHovered else { return }
            self.isShown = false
            self.onHide()
        }
    }
}
