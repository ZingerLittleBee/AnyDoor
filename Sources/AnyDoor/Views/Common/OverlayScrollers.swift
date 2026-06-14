import SwiftUI
import AppKit

/// Forces the enclosing `NSScrollView` to use **overlay** scrollers — floating,
/// auto-hiding, and reserving no layout width — matching Raycast. SwiftUI's
/// `ScrollView` otherwise honors the system "Show scroll bars" preference, so a
/// user set to "Always" gets a persistent, space-consuming legacy scrollbar.
///
/// Apply to the scroll *content* (e.g. the `LazyVStack`), not the `ScrollView`
/// itself, so the helper view lands inside the document view and can resolve its
/// `enclosingScrollView`.
extension View {
    func overlayScrollers() -> some View {
        background(OverlayScrollerSetter())
    }
}

private struct OverlayScrollerSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view isn't in the hierarchy yet during make; defer the lookup.
        DispatchQueue.main.async { Self.apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply: SwiftUI can recreate the scroll view and reset the style.
        DispatchQueue.main.async { Self.apply(from: nsView) }
    }

    private static func apply(from view: NSView) {
        // Prefer the document view's own scroll view; fall back to scanning the
        // palette window (it hosts a single list scroll view) if the background
        // view didn't land inside the document view.
        let scrollView = view.enclosingScrollView
            ?? view.window?.contentView.flatMap(firstScrollView(in:))
        guard let scrollView else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.scrollerStyle = .overlay
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}
