import Foundation

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
///
/// Reports the outcome through a bottom-center toast: success on completion,
/// a hint when the Trash is already empty, or a permission prompt when
/// Automation access is denied. Every error is absorbed and mapped to a toast
/// — `run()` never propagates.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

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
            cachedPermission = .granted
            let key: L10n.Key = result == "empty"
                ? .toastEmptyTrashAlreadyEmpty
                : .toastEmptyTrashSuccess
            let msg = await MainActor.run { L(key) }
            await ToastPresenter.shared.show(.success(msg))
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            let msg = await MainActor.run { L(.toastEmptyTrashPermissionDenied) }
            await ToastPresenter.shared.show(.failure(msg))
        } catch BuiltinError.appleScriptFailed(let code, _) where code == -128 {
            // -128 is userCanceledErr: the user dismissed Finder's confirmation
            // dialog. Treat it as an intentional no-op — stay silent.
            cachedPermission = .granted
        } catch {
            let msg = await MainActor.run { L(.toastEmptyTrashFailed) }
            await ToastPresenter.shared.show(.failure(msg))
        }
    }
}
