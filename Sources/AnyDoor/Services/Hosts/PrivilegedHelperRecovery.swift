import Foundation
import PluginInterface
import ServiceManagement

/// Owns a single service replacement across reentrant callers. Its lifetime is
/// shared with HelperManager, not a Hosts view or one cancellable write task.
@MainActor
final class PrivilegedHelperRecovery {
    private let validateVersion: @MainActor () async throws -> Void
    private let unregister: @MainActor () async throws -> Void
    private let register: @MainActor () throws -> Void
    private let sleep: @MainActor (Duration) async throws -> Void
    private var task: Task<Void, Error>?
    private(set) var needsRegistration = false

    var isRecovering: Bool { task != nil }

    init(
        validateVersion: @escaping @MainActor () async throws -> Void,
        unregister: @escaping @MainActor () async throws -> Void,
        register: @escaping @MainActor () throws -> Void,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.validateVersion = validateVersion
        self.unregister = unregister
        self.register = register
        self.sleep = sleep
    }

    func waitForRecovery() async throws {
        if let task {
            try await task.value
        } else if needsRegistration {
            // A previous replacement removed the daemon but could not restore
            // it. Later consumers, including shutdown, must repair it first.
            try await recover()
        }
    }

    /// Explicit uninstall ends our obligation to restore the shared service.
    /// HelperManager calls this only after successful release, with no task active.
    func registrationWasRemoved() {
        needsRegistration = false
    }

    func recover() async throws {
        if let task {
            try await task.value
            return
        }

        let operation = Task {
            // Another caller may already have replaced the daemon after this
            // caller's original probe. Do not restart a compatible helper.
            if !needsRegistration {
                do {
                    try await validateVersion()
                    return
                } catch let error as PrivilegedHelperCallError where error.message == "helper_outdated" {
                    // Only a confirmed mismatch permits changing service state.
                }
                try await unregister()
                needsRegistration = true
            }
            // SMAppService's async completion waits for the old process to die.
            // Always restore registration, even if the originating write was
            // cancelled: forced Scheduled Shutdown shares this daemon.
            try await restoreRegistration()
        }
        task = operation
        defer { task = nil }
        try await operation.value
    }

    private func restoreRegistration() async throws {
        let delays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]
        var attempt = 0
        while true {
            do {
                try register()
                needsRegistration = false
                return
            } catch {
                guard Self.canRetryRegistration(error), attempt < delays.count else { throw error }
                try await sleep(delays[attempt])
                attempt += 1
            }
        }
    }

    nonisolated static func canRetryRegistration(_ error: Error) -> Bool {
        let error = error as NSError
        // The named domain constant requires macOS 15, while AnyDoor supports 14.
        // SMAppService can return EPERM immediately after completed unregister;
        // authorization denial and invalid signatures have distinct SM codes.
        guard error.domain == "SMAppServiceErrorDomain" else { return false }
        return [Int(EPERM), kSMErrorInternalFailure, kSMErrorServiceUnavailable].contains(error.code)
    }
}
