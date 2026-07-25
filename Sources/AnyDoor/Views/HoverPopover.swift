import PluginInterface
import PluginSupport
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
    private let containerView: NSView
    private let hostingView: NSHostingView<AnyView>
    /// Reusable, never-displayed scratch host used only to read `fittingSize`.
    /// Created once and its `rootView` swapped per measure, so showing a popover
    /// no longer allocates a throwaway `NSHostingView` (which rebuilt the whole
    /// SwiftUI graph from scratch) on every hover/crossing. The live
    /// `hostingView` keeps `sizingOptions = []` so it can never drive a
    /// window-resize recursion (see `MenuBarController.showPanel`).
    private let measuringView: NSHostingView<AnyView>
    private var hideTask: Task<Void, Never>?
    // nonisolated(unsafe) so deinit can remove observers without a MainActor hop.
    @ObservationIgnored nonisolated(unsafe) private var keyObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    /// Set to `true` for popovers whose SwiftUI content needs first-responder focus
    /// (e.g. TextField). Leave `false` for read-only popovers — they keep the
    /// historical "never becomes key" behaviour.
    var needsKeyFocus: Bool = false {
        didSet { panel.allowKey = needsKeyFocus }
    }

    init<Content: View>(@ViewBuilder content: () -> Content) {
        let rootView = AnyView(content().focusEffectDisabled())

        let measuringView = NSHostingView(rootView: rootView)
        measuringView.sizingOptions = .intrinsicContentSize
        measuringView.layoutSubtreeIfNeeded()
        self.measuringView = measuringView

        let measured = measuringView.fittingSize
        let initialSize = (measured.width > 0 && measured.height > 0)
            ? measured
            : NSSize(width: 240, height: 200)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        hostingView.autoresizingMask = [.width, .height]

        let containerView = NSView(frame: NSRect(origin: .zero, size: initialSize))
        containerView.addSubview(hostingView)
        self.containerView = containerView
        self.hostingView = hostingView

        let panel = KeyableHoverPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = containerView
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        self.panel = panel

        // Track key state so MenuBarView can guard onDisappear.
        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.isHoldingFocus = true }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.isHoldingFocus = false }
        }
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func updateContent<Content: View>(@ViewBuilder content: () -> Content) {
        let rootView = AnyView(content().focusEffectDisabled())
        // Measure on the reusable scratch host first, then install + resize in
        // one pass. The live host lays out once at its final size instead of
        // once before measuring and again after the resize.
        let size = measure(rootView)
        hostingView.rootView = rootView
        resizePanel(to: size)
    }

    private func measure(_ rootView: AnyView) -> NSSize {
        measuringView.rootView = rootView
        measuringView.layoutSubtreeIfNeeded()
        let fitting = measuringView.fittingSize
        if fitting.width > 0 && fitting.height > 0 { return fitting }
        return panel.frame.size
    }

    /// Show the popover anchored to the right side of `referenceFrame` (screen coordinates).
    func show(anchoredTo referenceFrame: NSRect) {
        hideTask?.cancel()
        hideTask = nil

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(referenceFrame) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? .zero
        let origin = Self.anchorOrigin(
            referenceFrame: referenceFrame,
            size: panel.frame.size,
            screenFrame: screenFrame
        )

        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        if needsKeyFocus {
            panel.makeKey()
        }
    }

    /// Compute the popover's bottom-left origin (AppKit screen coordinates).
    ///
    /// Horizontally it sits just to the right of `referenceFrame`, flipping to
    /// the left only when there isn't room on the right. Vertically it aligns
    /// the popover's **top** edge with the row's top edge (a drop-down submenu
    /// feel), shifting up only when a tall popover would overflow the bottom of
    /// the screen — i.e. top-aligned by default, clamped on-screen otherwise.
    static func anchorOrigin(referenceFrame: NSRect, size: NSSize, screenFrame: NSRect) -> NSPoint {
        let rightX = referenceFrame.maxX + 4
        let leftX = referenceFrame.minX - 4 - size.width
        let originX = (rightX + size.width <= screenFrame.maxX) ? rightX : leftX

        // Top of popover (origin.y + height) == top of the row (referenceFrame.maxY).
        var originY = referenceFrame.maxY - size.height
        // Don't let the top run past the top of the screen.
        originY = min(originY, screenFrame.maxY - size.height)
        // Don't let the bottom run past the bottom of the screen.
        originY = max(originY, screenFrame.minY)
        return NSPoint(x: originX, y: originY)
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

    private func resizePanel(to size: NSSize) {
        guard size.width > 0 && size.height > 0 else { return }
        panel.setContentSize(size)
        containerView.frame = NSRect(origin: .zero, size: size)
        hostingView.frame = NSRect(origin: .zero, size: size)
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
    /// Hover-intent debounce before the first popover appears.
    static let showDelay: Duration = .milliseconds(400)
    /// Grace period before the popover auto-hides once nothing is hovered.
    static let hideDelay: Duration = .milliseconds(300)
    /// Coalescing window for re-mounts while the popover is already shown.
    /// Collapses a fast sweep across several hover rows into one mount and
    /// keeps the work off the AppKit mouse-event tick (~one display frame).
    static let refreshDelay: Duration = .milliseconds(16)

    /// Injected so tests can drive these deadlines with a fake clock instead of
    /// sleeping for real. Production always gets `ContinuousClock`.
    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.clock = clock
    }

    private(set) var isShown = false
    private var triggerHovered = false
    private var popoverHovered = false
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    var onShow: () -> Void = {}
    var onHide: () -> Void = {}

    func triggerHover(_ hovered: Bool) {
        triggerHovered = hovered
        if hovered { scheduleShow() } else { scheduleHide() }
    }

    func popoverHover(_ hovered: Bool) {
        popoverHovered = hovered
        if hovered {
            // Cancel AND nil, like every other cancel site: a cancelled-but-
            // pending showTask would otherwise wedge the `guard showTask == nil`
            // leading-edge re-arm in scheduleShow until it self-heals on wake.
            showTask?.cancel(); showTask = nil
            refreshTask?.cancel(); refreshTask = nil
            hideTask?.cancel()
        } else {
            scheduleHide()
        }
    }

    func showImmediately() {
        showTask?.cancel(); showTask = nil
        refreshTask?.cancel(); refreshTask = nil
        hideTask?.cancel()
        if !isShown { isShown = true }
        onShow()
    }

    /// Forcibly reset all tracked hover state. Used by the port-manager ESC
    /// path to clear the gate before the popover is dismissed programmatically.
    func reset() {
        showTask?.cancel()
        hideTask?.cancel()
        refreshTask?.cancel()
        showTask = nil
        hideTask = nil
        refreshTask = nil
        triggerHovered = false
        popoverHovered = false
        if isShown {
            isShown = false
            onHide()
        }
    }

    private func scheduleShow() {
        hideTask?.cancel()
        if isShown {
            // Already visible: a row-to-row crossing only needs to re-mount the
            // new content. Coalesce these off the mouse-event tick so a fast
            // sweep doesn't rebuild the popover once per row crossed.
            scheduleRefresh()
            return
        }
        // Leading-edge: keep the first hover's deadline instead of restarting
        // the 400ms countdown on every crossing. Whichever row the cursor rests
        // on when the timer fires is shown via the caller's latest target.
        guard showTask == nil else { return }
        let clock = clock
        showTask = Task { [weak self] in
            try? await clock.sleep(for: Self.showDelay)
            guard let self else { return }
            self.showTask = nil
            guard !Task.isCancelled, self.triggerHovered else { return }
            self.isShown = true
            self.onShow()
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        let clock = clock
        refreshTask = Task { [weak self] in
            try? await clock.sleep(for: Self.refreshDelay)
            guard let self else { return }
            self.refreshTask = nil
            guard !Task.isCancelled, self.isShown else { return }
            self.onShow()
        }
    }

    private func scheduleHide() {
        guard isShown else { return }
        hideTask?.cancel()
        let clock = clock
        hideTask = Task { [weak self] in
            try? await clock.sleep(for: Self.hideDelay)
            guard let self, !Task.isCancelled else { return }
            guard !self.triggerHovered && !self.popoverHovered else { return }
            self.isShown = false
            self.onHide()
        }
    }
}
