import Foundation
import PluginInterface

/// Safely executes an AppleScript on a background thread and reports errors.
///
/// NSAppleScript blocks the calling thread until completion (sometimes hundreds of ms).
/// Running it on the main thread would block the UI and risk the CGEvent tap timeout.
enum AppleScriptRunner {
    /// Run a script and return its stringified result. Throws `BuiltinError.appleScriptFailed`
    /// on any AppleScript error.
    static func run(_ source: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: source) else {
                throw BuiltinError.appleScriptFailed(code: -1, message: "NSAppleScript init failed")
            }
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if let info = errorInfo as? [String: Any] {
                let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (info[NSAppleScript.errorMessage] as? String) ?? "Unknown"
                if code == -1743 {
                    throw BuiltinError.missingAutomationPermission
                }
                throw BuiltinError.appleScriptFailed(code: code, message: message)
            }
            return result.stringValue ?? ""
        }.value
    }
}
