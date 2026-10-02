import Foundation

/// Executes one claimed built-in command. Providers are contributed by their
/// owner — the Core provider registry today, a Native Plugin once the command
/// is claimed by one — and the panel/hotkey paths invoke them by `itemKey`.
///
/// Failure contract: a provider that reports its own outcome (a toast for
/// each result, a silent cancel) returns normally. A thrown error has not been
/// reported yet: the host logs it and shows one failure notice naming the
/// command, so a provider that throws must not also show its own.
public protocol BuiltinProvider: Sendable {
    var itemKey: BuiltinItem { get }
    var permission: PermissionStatus { get async }
}

public protocol ToggleProvider: BuiltinProvider {
    /// The switch's current state. A failure during a passive refresh (the
    /// panel or the palette appearing) keeps the row's last state and shows
    /// nothing; a failure while toggling fails the toggle, like `setState`.
    func readState() async throws -> Bool
    /// Turns the switch on or off. Throwing leaves the row's state unchanged,
    /// and the host shows the failure notice.
    func setState(_ enabled: Bool) async throws
}

public protocol ActionProvider: BuiltinProvider {
    /// Runs the command. Throw only for a failure nothing has reported yet;
    /// the host shows the failure notice. A provider that reports its own
    /// outcome returns normally instead.
    func run() async throws
}

public enum BuiltinError: Error, Sendable {
    case missingAutomationPermission
    case appleScriptFailed(code: Int, message: String)
    case shellFailed(code: Int32, output: String)
    case audioDeviceUnavailable
    case ioKitFailed(Int32)
    /// The current audio device exposes no settable mute property (common for
    /// built-in mics / AirPods in the input scope).
    case muteUnsupported
}
