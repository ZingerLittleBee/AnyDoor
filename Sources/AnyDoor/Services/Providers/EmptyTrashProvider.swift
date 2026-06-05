import Foundation

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
///
/// Reports the outcome through a bottom-center toast: success on completion,
/// or a permission prompt when Automation access is denied. Every error is
/// absorbed and mapped to a toast — `run()` never propagates.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

    func run() async {
        do {
            _ = try await AppleScriptRunner.run("""
                tell application "Finder"
                    empty the trash
                end tell
            """)
            cachedPermission = .granted
            let msg = await MainActor.run { L(.toastEmptyTrashSuccess) }
            await ToastPresenter.shared.show(.success(msg))
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            let msg = await MainActor.run { L(.toastEmptyTrashPermissionDenied) }
            await ToastPresenter.shared.show(.failure(msg))
        } catch {
            let msg = await MainActor.run { L(.toastEmptyTrashFailed) }
            await ToastPresenter.shared.show(.failure(msg))
        }
    }
}
