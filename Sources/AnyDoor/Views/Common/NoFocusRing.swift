import SwiftUI
import AppKit

/// Removes the AppKit keyboard focus ring from the backing `NSControl` of a
/// SwiftUI control (e.g. a `Toggle(.checkbox)`'s `NSButton`).
///
/// SwiftUI's `.focusEffectDisabled()` does not suppress the focus ring that an
/// AppKit checkbox draws itself, so reach the backing control and set
/// `focusRingType = .none` directly — the same introspection approach used by
/// `overlayScrollers()`.
extension View {
    func noFocusRing() -> some View {
        background(NoFocusRingSetter())
    }
}

private struct NoFocusRingSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NoFocusRingProbe { NoFocusRingProbe() }
    func updateNSView(_ nsView: NoFocusRingProbe, context: Context) { nsView.applyOrRetry() }
}

/// Background sensor whose only job is to strip the focus ring from its sibling
/// control.
private final class NoFocusRingProbe: NSView {
    // Click-transparent: a background sensor must never intercept clicks meant
    // for the control in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOrRetry()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyOrRetry()
    }

    /// Apply synchronously; if the control isn't attached yet, retry once on the
    /// next runloop (the hosting control can land a layout pass after this probe).
    func applyOrRetry() {
        if apply() { return }
        DispatchQueue.main.async { [weak self] in _ = self?.apply() }
    }

    @discardableResult
    private func apply() -> Bool {
        // The probe lands beside the control as a `.background`; climb to the
        // shared superview and disable the focus ring on the nearest control in
        // its subtree.
        var ancestor = superview
        while let current = ancestor {
            if let control = Self.firstControl(in: current, excluding: self) {
                control.focusRingType = .none
                return true
            }
            ancestor = current.superview
        }
        return false
    }

    private static func firstControl(in view: NSView, excluding probe: NSView) -> NSControl? {
        if view === probe { return nil }
        if let control = view as? NSControl { return control }
        for subview in view.subviews {
            if let found = firstControl(in: subview, excluding: probe) { return found }
        }
        return nil
    }
}
