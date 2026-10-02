import Foundation
import PluginInterface

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
///
/// Reports the outcome through a bottom-center toast: success on completion,
/// a hint when the Trash is already empty, or a permission prompt when
/// Automation access is denied. Every error is absorbed and mapped to a toast
/// — `run()` never propagates.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    /// Finder's Automation verdict. A check never launches Finder: while
    /// Finder isn't running, the last verdict stands.
    private let automation: AutomationPermissionCheck

    /// `checkTimeout` bounds how long a `permission` read waits for Finder;
    /// `determineAutomationPermission` is the non-prompting Finder check,
    /// injected so tests never reach TCC.
    init(
        checkTimeout: Duration = .seconds(1),
        determineAutomationPermission: @escaping @Sendable () -> OSStatus = {
            AutomationPermission.determine(target: "com.apple.finder", askUserIfNeeded: false)
        }
    ) {
        automation = AutomationPermissionCheck(
            target: "com.apple.finder",
            timeout: checkTimeout,
            determine: determineAutomationPermission
        )
    }

    /// Checked live on every read, so a grant made in System Settings clears
    /// the panel row's "needs permission" state on the next panel or palette
    /// open (`PanelStore.refreshAll()`). A denied row only opens System
    /// Settings and never runs the action, so a status refreshed only by
    /// `run()` would stay denied after the grant. A read waits at most
    /// `checkTimeout` for a Finder that stops answering, and then reports the
    /// last verdict (see `AutomationPermissionCheck`).
    var permission: PermissionStatus {
        get async { await automation.status }
    }

    func run() async {
        do {
            // Finder throws -128 when `empty the trash` runs on an already-empty
            // Trash, so short-circuit that case and surface a distinct hint
            // instead of a spurious failure. The marker keeps the success and
            // already-empty paths apart without parsing localized output.
            let result = try await AppleScriptRunner.run("""
                tell application "Finder"
                    if (count of items in trash) is 0 then return "empty"
                    empty the trash
                    return "done"
                end tell
            """)
            await automation.record(.granted)
            let key: L10n.Key = result == "empty"
                ? .toastEmptyTrashAlreadyEmpty
                : .toastEmptyTrashSuccess
            let msg = await MainActor.run { L(key) }
            await ToastPresenter.shared.show(.success(msg))
        } catch BuiltinError.missingAutomationPermission {
            await automation.record(.denied)
            let msg = await MainActor.run { L(.toastEmptyTrashPermissionDenied) }
            await ToastPresenter.shared.show(.failure(msg))
        } catch BuiltinError.appleScriptFailed(let code, _) where code == -128 {
            // -128 is userCanceledErr: the user dismissed Finder's confirmation
            // dialog. Treat it as an intentional no-op — stay silent.
            await automation.record(.granted)
        } catch {
            let msg = await MainActor.run { L(.toastEmptyTrashFailed) }
            await ToastPresenter.shared.show(.failure(msg))
        }
    }
}
