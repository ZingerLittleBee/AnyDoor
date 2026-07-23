import Foundation

/// Executes one claimed built-in command. Providers are contributed by their
/// owner — the Core provider registry today, a Native Plugin once the command
/// is claimed by one — and the panel/hotkey paths invoke them by `itemKey`.
public protocol BuiltinProvider: Sendable {
    var itemKey: BuiltinItem { get }
    var permission: PermissionStatus { get async }
}

public protocol ToggleProvider: BuiltinProvider {
    func readState() async throws -> Bool
    func setState(_ enabled: Bool) async throws
}

public protocol ActionProvider: BuiltinProvider {
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
