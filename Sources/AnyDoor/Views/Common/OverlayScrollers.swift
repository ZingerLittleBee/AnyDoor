import SwiftUI
import AppKit

/// Forces the enclosing `NSScrollView` to use **overlay** scrollers — floating,
/// auto-hiding, and reserving no layout width — matching Raycast.
///
/// The app-wide `AppleShowScrollBars = WhenScrolling` default set in
/// `AppDelegate.init` already makes every scroll view overlay from birth, so
/// this modifier is now a localized **reinforcement**: it re-asserts the style
/// on a specific scroll view in case anything resets it. Apply to the scroll
/// *content* (e.g. the `LazyVStack`), or — for a `Form` / `List`, whose scroll
/// view can't be reached from inside — to the container itself; the probe
/// resolves the scroll view either way (see `OverlayScrollerProbe`).
extension View {
    func overlayScrollers() -> some View {
        background(OverlayScrollerSetter())
    }
}

private struct OverlayScrollerSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> OverlayScrollerProbe {
        OverlayScrollerProbe()
    }

    func updateNSView(_ nsView: OverlayScrollerProbe, context: Context) {
        // SwiftUI can recreate the scroll view and reset the style; re-assert it.
        nsView.applyOrRetry()
    }
}

/// Background sensor whose only job is to force its sibling scroll view to the
/// overlay scroller style.
private final class OverlayScrollerProbe: NSView {
    // Click-transparent: a background sensor must never intercept clicks meant
    // for the content in front of it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyOrRetry()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyOrRetry()
    }

    /// Apply synchronously; if the scroll view isn't reachable yet, retry once on
    /// the next runloop.
    ///
    /// Scroll *content* (a `ScrollView`'s `LazyVStack`) resolves synchronously
    /// at attach time. A `Form` / `List`, however, inserts its scroll view in a
    /// *later* pass than this background probe, so the synchronous lookup misses
    /// it and only the deferred retry resolves it. That deferred retry is also
    /// exactly what used to repaint a legacy scroller one frame late — the
    /// "thick scrollbar flash" on tab switch — which is why the real fix is the
    /// launch-time `AppleShowScrollBars` default that makes the scroll view
    /// overlay from birth; here the retry then only re-asserts an already-overlay
    /// style, so it can't flash.
    func applyOrRetry() {
        if applyOverlayStyle() { return }
        DispatchQueue.main.async { [weak self] in _ = self?.applyOverlayStyle() }
    }

    @discardableResult
    private func applyOverlayStyle() -> Bool {
        guard let scrollView = resolveScrollView() else { return false }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.scrollerStyle = .overlay
        return true
    }

    /// Resolve the scroll view this probe should restyle.
    ///
    /// Inside scroll content the probe sits within the document view, so
    /// `enclosingScrollView` resolves directly. As a `.background` of a `Form` /
    /// `List` it lands *beside* — not inside — the form's scroll view, so
    /// `enclosingScrollView` is nil; climb the superview chain and return the
    /// nearest scroll view found in an ancestor's subtree. Climbing locally
    /// (rather than scanning the whole window) matters inside a `TabView`: hidden
    /// tabs can keep their own scroll views in the hierarchy, so a window-wide
    /// scan could restyle the wrong tab's list. The lowest common ancestor of
    /// this probe and its form's scroll view yields the correct one first.
    private func resolveScrollView() -> NSScrollView? {
        if let enclosing = enclosingScrollView { return enclosing }
        var ancestor = superview
        while let current = ancestor {
            if let found = Self.firstScrollView(in: current) { return found }
            ancestor = current.superview
        }
        return nil
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
