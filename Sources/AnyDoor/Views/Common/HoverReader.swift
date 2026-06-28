import AppKit
import SwiftUI

/// AppKit-backed replacement for SwiftUI's `.onHover`.
///
/// On the Swift 6.3.2 / macOS 26 toolchain, SwiftUI dispatches its `.onHover`
/// `@MainActor` callback through an async path that can resume **off the main
/// thread**. The runtime confirms this directly under
/// `SWIFT_UNEXPECTED_EXECUTOR_LOG_LEVEL=1`:
///
///     warning: data race detected: @MainActor function at MenuBarView.swift:NNN
///     was not called on the main thread
///
/// The compiler-inserted actor-isolation check guarding the `@MainActor` closure
/// then dereferences a bad executor and crashes with EXC_BAD_ACCESS / SIGBUS in
/// `swift_task_isCurrentExecutor`. This is the signature behind the "screenshot
/// freeze + crash" report and every other menu-hover crash on this toolchain.
///
/// `NSTrackingArea`'s `mouseEntered` / `mouseExited` are delivered by AppKit's
/// statically-`@MainActor` `NSView` methods, always on the main thread, so the
/// handler is a static same-isolation call with no dynamic executor check — it
/// cannot hit that bug. Use `.onHoverSafe` instead of `.onHover` for any hover
/// handler that touches main-actor state.
struct HoverReader: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: HoverTrackingView, context: Context) {
        nsView.onChange = onChange
    }

    final class HoverTrackingView: NSView {
        var onChange: (@MainActor (Bool) -> Void)?
        private var inside = false
        private var trackedBounds: NSRect = .null

        // Click-transparent: this is a background hover sensor only. Tracking-area
        // enter/exit events are delivered regardless of hit-testing, so returning
        // nil lets clicks fall through to the row content in front.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            // Use an explicit `bounds`-sized tracking rect instead of
            // `.inVisibleRect`. For rows SwiftUI hosts inside a `ScrollView` —
            // especially ones inserted by a collapse/expand `.transition` — an
            // `.inVisibleRect` area can stop delivering enter/exit crossings even
            // though it is installed with the correct geometry, so the hover state
            // never updates. An explicit rect, rebuilt only when `bounds` actually
            // changes (not on every scroll-driven layout pass), is reliable; the
            // "re-add drops the enter edge" gap is covered by `reconcileHover()`.
            if trackingAreas.isEmpty || trackedBounds != bounds {
                trackingAreas.forEach(removeTrackingArea)
                trackedBounds = bounds
                // `.activeAlways` so a non-activating menu panel still tracks hover.
                addTrackingArea(NSTrackingArea(
                    rect: bounds,
                    options: [.activeAlways, .mouseEnteredAndExited],
                    owner: self
                ))
            }
            // Reconcile against the live cursor: if a layout/attach left the cursor
            // resting inside (or outside) the view without a crossing event, emit
            // the edge that AppKit skipped so the hover state can't get stuck.
            reconcileHover()
        }

        /// Recover a missing enter/exit edge by comparing the actual cursor
        /// position to the tracked `inside` flag. See `updateTrackingAreas`.
        private func reconcileHover() {
            guard let window, window.isVisible else { return }
            let pointInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            let nowInside = bounds.contains(pointInView)
            guard nowInside != inside else { return }
            inside = nowInside
            onChange?(nowInside)
        }

        nonisolated override func mouseEntered(with event: NSEvent) {
            MainThreadIsolation.run {
                guard !inside else { return }
                inside = true
                onChange?(true)
            }
        }

        nonisolated override func mouseExited(with event: NSEvent) {
            MainThreadIsolation.run {
                guard inside else { return }
                inside = false
                onChange?(false)
            }
        }
    }
}

extension View {
    /// Drop-in replacement for `.onHover(perform:)` that routes hover detection
    /// through AppKit (`HoverReader`) so the callback always runs on the main
    /// thread without a dynamic actor-isolation check. See `HoverReader`.
    func onHoverSafe(perform action: @MainActor @escaping (Bool) -> Void) -> some View {
        background { HoverReader(onChange: action) }
    }
}
