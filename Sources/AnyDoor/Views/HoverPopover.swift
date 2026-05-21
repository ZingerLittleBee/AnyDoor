import SwiftUI
import AppKit
import Observation

/// Hover-triggered NSPanel popover.
///
/// Used by both App Shortcuts (`needsKeyFocus = false`, read-only) and Port Manager
/// (`needsKeyFocus = true`, needs to receive text input and local key events).
///
/// Lifecycle:
/// - Trigger view installs `onHover` that arms the gate after 400ms.
/// - Popover stays open while either trigger or popover is hovered (gate manages).
/// - Closes 300ms after both lose hover, OR immediately via `hide()`.
@MainActor
@Observable
final class HoverPopover {
    /// True while the underlying panel is keyWindow. Read by MenuBarView.onDisappear
    /// to avoid hiding the popover when the menu bar panel collapses because we just
    /// took key focus.
    private(set) var isHoldingFocus: Bool = false

    private let panel: KeyableHoverPanel
    private let hostingController: NSHostingController<AnyView>
    private var hideTask: Task<Void, Never>?
    // nonisolated(unsafe) so deinit can access them without MainActor hop.
    nonisolated(unsafe) private var keyObserver: NSObjectProtocol?
    nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    /// Set to `true` for popovers whose SwiftUI content needs first-responder focus
    /// (e.g. TextField). Leave `false` for read-only popovers — they keep the
    /// historical "never becomes key" behaviour.
    var needsKeyFocus: Bool = false {
        didSet { panel.allowKey = needsKeyFocus }
    }

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let controller = NSHostingController(rootView: AnyView(content()))
        controller.sizingOptions = [.preferredContentSize]
        self.hostingController = controller

        let panel = KeyableHoverPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentViewController = controller
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        self.panel = panel

        // Track key state so MenuBarView can guard onDisappear.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHoldingFocus = true }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isHoldingFocus = false }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func updateContent<Content: View>(@ViewBuilder content: () -> Content) {
        hostingController.rootView = AnyView(content())
        hostingController.view.layoutSubtreeIfNeeded()
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0 && fitting.height > 0 {
            panel.setContentSize(fitting)
        }
    }

    /// Show the popover anchored to the right side of `referenceFrame` (screen coordinates).
    func show(anchoredTo referenceFrame: NSRect) {
        hideTask?.cancel()
        hideTask = nil

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero

        let size = panel.frame.size
        let rightX = referenceFrame.maxX + 4
        let leftX = referenceFrame.minX - 4 - size.width
        let originX = (rightX + size.width <= screenFrame.maxX) ? rightX : leftX
        let originY = max(screenFrame.minY,
                          min(referenceFrame.midY - size.height / 2,
                              screenFrame.maxY - size.height))

        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
        panel.orderFrontRegardless()
        if needsKeyFocus {
            panel.makeKey()
        }
    }

    func scheduleHide(after delay: TimeInterval = 0.3) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }

    func keepOpen() {
        hideTask?.cancel()
        hideTask = nil
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        panel.orderOut(nil)
    }
}

/// NSPanel subclass whose key-eligibility is controlled by an opt-in flag.
/// App Shortcuts uses `allowKey = false` (read-only), Port Manager uses `true`.
final class KeyableHoverPanel: NSPanel {
    var allowKey: Bool = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
}

// MARK: - HoverGate (unchanged plus new reset())

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

    /// Forcibly reset all tracked hover state. Used by the port-manager ESC
    /// path to clear the gate before the popover is dismissed programmatically.
    func reset() {
        showTask?.cancel()
        hideTask?.cancel()
        showTask = nil
        hideTask = nil
        triggerHovered = false
        popoverHovered = false
        if isShown {
            isShown = false
            onHide()
        }
    }

    private func scheduleShow() {
        guard !isShown else { return }
        hideTask?.cancel()
        showTask?.cancel()
        showTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, !Task.isCancelled, self.triggerHovered else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func scheduleHide() {
        guard isShown else { return }
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            guard !self.triggerHovered && !self.popoverHovered else { return }
            self.isShown = false
            self.onHide()
        }
    }
}
