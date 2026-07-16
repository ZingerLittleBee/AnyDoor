import AppKit
import PluginInterface

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
            // Run synchronously on the main thread via MainThreadIsolation rather
            // than MainActor.assumeIsolated, whose swift_task_isCurrentExecutor
            // check can fault on the main thread after a ScreenCaptureKit capture
            // (see MainThreadIsolation).
            MainThreadIsolation.run { self?.untrack(id) }
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
