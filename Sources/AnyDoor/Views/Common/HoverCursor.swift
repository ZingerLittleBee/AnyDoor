import PluginInterface
import AppKit
import SwiftUI

/// Shows an interactive pointer (open hand for a drag handle, pointing hand for a
/// clickable control) while the pointer is over the view.
///
/// On macOS 15+ this uses SwiftUI's declarative `.pointerStyle`, which AppKit
/// re-establishes on every render. That matters for rows that churn — the Panel
/// settings list recreates rows as groups collapse/expand and reorder — where the
/// imperative `NSCursor.push()/pop()` path desyncs its balance against the live
/// cursor stack and the cursor gets stuck on the default arrow. The push/pop path
/// is kept as the macOS 14 fallback, built on `onHoverSafe` (AppKit tracking) so
/// the callback is always delivered on the main thread, and balanced on exit and
/// on disappear so a row removed mid-hover can't leak a pushed cursor.
private struct HoverCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var pushed = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(Self.pointerStyle(for: cursor))
        } else {
            content
                .onHoverSafe { inside in
                    if inside {
                        guard !pushed else { return }
                        cursor.push()
                        pushed = true
                    } else if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
                .onDisappear {
                    if pushed {
                        NSCursor.pop()
                        pushed = false
                    }
                }
        }
    }

    /// Maps the requested `NSCursor` to the matching declarative `PointerStyle`.
    @available(macOS 15.0, *)
    private static func pointerStyle(for cursor: NSCursor) -> PointerStyle {
        if cursor === NSCursor.openHand { return .grabIdle }
        if cursor === NSCursor.pointingHand { return .link }
        return .default
    }
}

extension View {
    /// Show `cursor` while hovering this view — e.g. `.pointingHand` for a
    /// clickable row/button, `.openHand` for a drag handle.
    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursorModifier(cursor: cursor))
    }
}
