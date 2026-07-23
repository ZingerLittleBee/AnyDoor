import Foundation
import PluginInterface

/// Toggle macOS dark mode via AppleScript to System Events.
///
/// Requires the user to grant Automation permission to "System Events". On first call,
/// the system prompts; if denied (errorNumber -1743), `permission` returns `.denied`.
actor DarkModeProvider: ToggleProvider {
    let itemKey: BuiltinItem = .darkMode

    private var cachedPermission: PermissionStatus = .undetermined

    var permission: PermissionStatus { cachedPermission }

    func readState() async throws -> Bool {
        do {
            let result = try await AppleScriptRunner.run("""
                tell application "System Events"
                    tell appearance preferences
                        return dark mode
                    end tell
                end tell
            """)
            cachedPermission = .granted
            return result.lowercased() == "true"
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }

    func setState(_ dark: Bool) async throws {
        do {
            _ = try await AppleScriptRunner.run("""
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to \(dark)
                    end tell
                end tell
            """)
            cachedPermission = .granted
        } catch BuiltinError.missingAutomationPermission {
            cachedPermission = .denied
            throw BuiltinError.missingAutomationPermission
        }
    }
}
