import Foundation
import PluginInterface

/// The notice and the log summary for an error a command's provider threw out
/// of `PanelStore.run`, `toggle` or `setKeepAwakeDuration`.
///
/// A provider that reports its own outcome returns normally (`BuiltinProvider`),
/// so a thrown error is one the user has not heard about yet; `PanelStore`
/// reports it exactly once, through here. Passive reads (`PanelStore.refreshAll`)
/// never report.
enum CommandFailure {
    /// What the user asked the command to do. It picks the generic notice's
    /// wording and names the attempt in the log.
    enum Attempt: String, Sendable {
        /// A switch press, from the panel row, a hotkey or the palette.
        case toggle = "Toggle"
        /// An action run.
        case run = "Run"
        /// A Keep Awake duration chosen from the clock menu or the palette.
        case applyDuration = "Apply"
    }

    /// The failure notice for `error`, or nil when it is not a failure: a
    /// cancelled task, or a script dialog the user dismissed (userCanceledErr).
    @MainActor
    static func toast(for error: any Error, command: BuiltinItem, attempt: Attempt) -> ToastStyle? {
        switch error {
        case is CancellationError, BuiltinError.appleScriptFailed(code: -128, message: _):
            return nil
        case BuiltinError.missingAutomationPermission:
            return .failure(L(.toastCommandNeedsAutomation, L(command.titleKey)))
        case BuiltinError.muteUnsupported where command == .microphoneMute:
            // The case names the input device, so only Microphone Mute uses it.
            return .failure(L(.toastMicMuteUnsupported))
        default:
            // "Toggle" carries no direction: many titles are imperatives
            // ("Hide Dock"), and a failed read leaves the direction unknown.
            let template: L10n.Key = attempt == .toggle
                ? .toastCommandToggleFailed
                : .toastCommandFailed
            return .failure(L(template, L(command.titleKey)))
        }
    }

    /// The error's type, case and numeric code. They carry no user data, so the
    /// log shows them publicly; tool output, script messages and paths are left
    /// out, and the caller logs the full error privately.
    static func logSummary(of error: any Error) -> String {
        guard let builtin = error as? BuiltinError else {
            let bridged = error as NSError
            return "\(bridged.domain) \(bridged.code)"
        }
        switch builtin {
        case .missingAutomationPermission:
            return "BuiltinError.missingAutomationPermission"
        case .appleScriptFailed(let code, _):
            return "BuiltinError.appleScriptFailed(code: \(code))"
        case .shellFailed(let code, _):
            return "BuiltinError.shellFailed(code: \(code))"
        case .audioDeviceUnavailable:
            return "BuiltinError.audioDeviceUnavailable"
        case .ioKitFailed(let status):
            return "BuiltinError.ioKitFailed(\(status))"
        case .muteUnsupported:
            return "BuiltinError.muteUnsupported"
        }
    }
}
