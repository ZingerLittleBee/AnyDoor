import AppKit
import SwiftUI

/// Keeps the app in `.regular` activation policy while any "real" window
/// (Settings, the Hosts editor) is open.
///
/// AnyDoor normally runs as `.accessory` (menu-bar only, no Dock icon). Under
/// that policy a standard window has no Dock / Cmd-Tab presence, so once the
/// user clicks another app it slips behind and cannot be resurfaced — it looks
/// like it vanished. While a tracked window is open we switch to `.regular` so
/// those windows behave like ordinary app windows (Dock icon, Cmd-Tab, stay
/// reachable); when the last one closes we revert to `.accessory`.
@MainActor
final class RegularWindowCoordinator {
    static let shared = RegularWindowCoordinator()

    private var tracked: Set<ObjectIdentifier> = []
    private var observers: [ObjectIdentifier: NSObjectProtocol] = [:]

    /// Begin tracking a window. Idempotent — safe to call again when a reused
    /// window is shown a second time.
    func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard tracked.insert(id).inserted else { return }
        observers[id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.untrack(id) }
        }
        apply()
    }

    private func untrack(_ id: ObjectIdentifier) {
        if let observer = observers.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(observer)
        }
        tracked.remove(id)
        apply()
    }

    private func apply() {
        NSApp.setActivationPolicy(tracked.isEmpty ? .accessory : .regular)
    }
}

/// Registers the hosting SwiftUI window with `RegularWindowCoordinator`. Attach
/// via `.background(RegularWindowRegistrar())` on a window's root view (e.g. the
/// Settings scene) so the app adopts `.regular` policy while that window lives.
struct RegularWindowRegistrar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view isn't attached to its window yet during makeNSView; defer the
        // lookup to the next runloop tick.
        DispatchQueue.main.async {
            if let window = view.window {
                // Opt this window out of state restoration so macOS does not
                // reopen Settings on the next launch. Complements the app-level
                // opt-out in `AppDelegate` for windows restored via a per-window
                // restoration class rather than the application state coder.
                window.isRestorable = false
                RegularWindowCoordinator.shared.track(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
