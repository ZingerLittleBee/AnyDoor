import Foundation

protocol BuiltinProvider: Sendable {
    var itemKey: BuiltinItem { get }
    var permission: PermissionStatus { get async }
}

protocol ToggleProvider: BuiltinProvider {
    func readState() async throws -> Bool
    func setState(_ enabled: Bool) async throws
}

protocol ActionProvider: BuiltinProvider {
    func run() async throws
}

enum BuiltinError: Error, Sendable {
    case missingAutomationPermission
    case appleScriptFailed(code: Int, message: String)
    case shellFailed(code: Int32, output: String)
    case audioDeviceUnavailable
    case ioKitFailed(Int32)
    /// The current audio device exposes no settable mute property (common for
    /// built-in mics / AirPods in the input scope).
    case muteUnsupported
}
