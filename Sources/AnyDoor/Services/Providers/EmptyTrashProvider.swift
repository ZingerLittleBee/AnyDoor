import Foundation

/// Empty the Trash via AppleScript to Finder. Requires Automation permission.
actor EmptyTrashProvider: ActionProvider {
    let itemKey: BuiltinItem = .emptyTrash

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

    func run() async throws {
        do {
            _ = try await AppleScriptRunner.run("""
                tell application "Finder"
                    empty the trash
                end tell
            """)
            cachedPermission = .granted
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }
}
