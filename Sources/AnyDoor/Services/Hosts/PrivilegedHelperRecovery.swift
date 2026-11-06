import Foundation
import PluginInterface

/// Owns a single service replacement across reentrant callers. Its lifetime is
/// shared with HelperManager, not a Hosts view or one cancellable write task.
@MainActor
final class PrivilegedHelperRecovery {
    private let validateVersion: @MainActor () async throws -> Void
    private let unregister: @MainActor () async throws -> Void
    private let register: @MainActor () throws -> Void
    private var task: Task<Void, Error>?

    var isRecovering: Bool { task != nil }

    init(
        validateVersion: @escaping @MainActor () async throws -> Void,
        unregister: @escaping @MainActor () async throws -> Void,
        register: @escaping @MainActor () throws -> Void
    ) {
        self.validateVersion = validateVersion
        self.unregister = unregister
        self.register = register
    }

    func waitForRecovery() async throws {
        try await task?.value
    }

    func recover() async throws {
        if let task {
            try await task.value
            return
        }

        let operation = Task {
            // Another caller may already have replaced the daemon after this
            // caller's original probe. Do not restart a compatible helper.
            do {
                try await validateVersion()
                return
            } catch let error as PrivilegedHelperCallError where error.message == "helper_outdated" {
                // Only a confirmed mismatch permits changing service state.
            }
            try await unregister()
            // SMAppService's async completion waits for the old process to die.
            // Always restore registration, even if the originating write was
            // cancelled: forced Scheduled Shutdown shares this daemon.
            try register()
        }
        task = operation
        defer { task = nil }
        try await operation.value
    }
}
