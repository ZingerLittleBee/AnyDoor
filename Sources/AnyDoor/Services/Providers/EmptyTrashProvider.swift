import CoreServices
import Foundation
import os
import PluginInterface

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
///
/// Reports the outcome through a bottom-center toast: success on completion,
/// a hint when the Trash is already empty, or a permission prompt when
/// Automation access is denied. Every error is absorbed and mapped to a toast
/// — `run()` never propagates.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    /// Non-prompting Finder Automation check. Injected so tests never reach TCC.
    private let determineAutomationPermission: @Sendable () -> OSStatus

    /// How long a `permission` read waits for the live check.
    private let checkTimeout: Duration

    /// Runs the blocking live check, so a Finder that stops answering ties up
    /// this queue rather than this actor or a cooperative thread.
    private let checkQueue = DispatchQueue(label: "dev.bybee.AnyDoor.empty-trash.permission")

    /// Last definite verdict, from a live check or from `run()`'s own Apple
    /// Event; reported when a live check gives none (Finder not running) or
    /// has not answered within `checkTimeout`.
    private var cachedPermission: PermissionStatus = .undetermined

    /// The live check in flight. Reads share it, so a Finder that stops
    /// answering never queues more checks behind the first one.
    private var runningCheck: Task<Void, Never>?

    init(
        checkTimeout: Duration = .seconds(1),
        determineAutomationPermission: @escaping @Sendable () -> OSStatus = {
            AutomationPermission.determine(target: "com.apple.finder", askUserIfNeeded: false)
        }
    ) {
        self.checkTimeout = checkTimeout
        self.determineAutomationPermission = determineAutomationPermission
    }

    /// Checked live on every read, so a grant made in System Settings clears
    /// the panel row's "needs permission" state on the next panel or palette
    /// open (`PanelStore.refreshAll()`). A denied row only opens System
    /// Settings and never runs the action, so a status refreshed only by
    /// `run()` would stay denied after the grant.
    ///
    /// The check waits for Finder itself to answer, so it blocks for as long
    /// as Finder hangs. A read therefore waits at most `checkTimeout` and then
    /// reports the last verdict; the check still records its own verdict
    /// whenever Finder answers.
    var permission: PermissionStatus {
        get async {
            let check = runningCheck ?? startCheck()
            await Self.wait(for: check, atMost: checkTimeout)
            return cachedPermission
        }
    }

    private func startCheck() -> Task<Void, Never> {
        let determine = determineAutomationPermission
        let queue = checkQueue
        let check = Task {
            let status: OSStatus = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: determine()) }
            }
            if let verdict = EmptyTrashProvider.verdict(for: status) {
                cachedPermission = verdict
            }
            runningCheck = nil
        }
        runningCheck = check
        return check
    }

    /// Returns once `check` finishes or `timeout` elapses, whichever comes
    /// first. Never cancels the check: a blocked Apple Event call can't be
    /// interrupted.
    private static func wait(for check: Task<Void, Never>, atMost timeout: Duration) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce: @Sendable () -> Void = {
                let isFirst = resumed.withLock { wasResumed in
                    defer { wasResumed = true }
                    return !wasResumed
                }
                if isFirst { continuation.resume() }
            }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                resumeOnce()
            }
            Task {
                await check.value
                resumeOnce()
                timer.cancel()
            }
        }
    }

    /// Maps a non-prompting check; nil when it gives no verdict, such as
    /// `procNotFound` while Finder isn't running.
    private static func verdict(for status: OSStatus) -> PermissionStatus? {
        switch status {
        case OSStatus(noErr): .granted
        case OSStatus(errAEEventNotPermitted): .denied
        // Not decided yet: the row stays runnable, so a click shows the system
        // prompt instead of sending the user to System Settings.
        case OSStatus(errAEEventWouldRequireUserConsent): .undetermined
        default: nil
        }
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
