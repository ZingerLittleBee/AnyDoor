import AppKit
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "windowLayout")

/// Bridges a single `WindowLayoutAction` into the panel's `ActionProvider`
/// surface. One instance per builtin item; the underlying work is delegated
/// to the shared `WindowLayoutService`.
///
/// `@MainActor` because the layout service is main-actor (it touches
/// `NSScreen` / `NSWorkspace`). Errors are caught here and surfaced as a
/// localized toast instead of propagating — a failed layout should never
/// block the user or crash.
@MainActor
final class WindowLayoutProvider: ActionProvider {
    let itemKey: BuiltinItem
    private let action: WindowLayoutAction

    init(item: BuiltinItem, action: WindowLayoutAction) {
        self.itemKey = item
        self.action = action
    }

    /// Window layout uses Accessibility, which the app already prompts for
    /// at startup via `HotkeyService`. The row itself stays `.notRequired`
    /// so the menu-bar UI doesn't double up on a permission badge; when AX
    /// is actually missing at invocation time, `run()` surfaces a toast
    /// pointing the user at the system setting.
    var permission: PermissionStatus { .notRequired }

    func run() async throws {
        do {
            try WindowLayoutService.shared.apply(action)
        } catch let error as WindowLayoutError {
            logger.error("Window layout \(self.action.rawValue) failed: \(String(describing: error))")
            ToastPresenter.shared.show(.failure(Self.message(for: error)))
        } catch {
            logger.error("Window layout \(self.action.rawValue) failed: \(error)")
            ToastPresenter.shared.show(.failure(L(.toastWindowLayoutFailed)))
        }
    }

    /// Map a `WindowLayoutError` to the user-facing toast string. Anything
    /// the user might be able to fix gets a specific hint; AX-internal
    /// failures collapse into the generic "operation failed" message so
    /// the UI doesn't leak status codes.
    @MainActor
    private static func message(for error: WindowLayoutError) -> String {
        switch error {
        case .missingAccessibilityPermission:
            return L(.toastWindowLayoutNeedsAccessibility)
        case .noFrontmostApplication, .noFocusedWindow:
            return L(.toastWindowLayoutNoWindow)
        case .fullScreenWindowNotSupported:
            return L(.toastWindowLayoutFullScreen)
        case .noScreenAvailable, .axCallFailed:
            return L(.toastWindowLayoutFailed)
        }
    }
}
