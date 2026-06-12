import AppKit
import SwiftUI

/// Hosts a native NSMenu for right-click / control-click on the SwiftUI view it
/// overlays. SwiftUI's `.contextMenu` renders menu-item icons through its own
/// bridge, which flash-resizes them when the menu opens on macOS 26; routing
/// through NSView's `menu(for:)` yields the same fully native menu Finder
/// shows, with the icon baked into `NSMenuItem.image`. Left clicks, hovers and
/// scrolls fall through to the SwiftUI content underneath (hit-testing is
/// gated by the current event type).
struct RightClickMenu: NSViewRepresentable {
    /// Builds the menu at click time, so per-item state (favorite flag, active
    /// language) is always current.
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> MenuCatcherView {
        let view = MenuCatcherView()
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: MenuCatcherView, context: Context) {
        view.makeMenu = makeMenu
    }

    final class MenuCatcherView: NSView {
        var makeMenu: (() -> NSMenu)?

        /// Claim only menu-summoning clicks; everything else passes through to
        /// the SwiftUI view below so taps, double-clicks and tooltips keep
        /// working.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            switch event.type {
            case .rightMouseDown, .rightMouseUp:
                return super.hitTest(point)
            case .leftMouseDown where event.modifierFlags.contains(.control):
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            makeMenu?()
        }
    }
}

/// NSMenuItem driven by a closure, for menus built by `RightClickMenu`.
/// `target` is `unowned(unsafe)` on NSMenuItem, so pointing it at the item
/// itself is safe: both live exactly as long as the menu.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, systemImage: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        if let systemImage {
            image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func invoke() { handler() }
}
