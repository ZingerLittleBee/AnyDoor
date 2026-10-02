import Foundation
import XCTest

public extension XCTestCase {
    /// Owns a resource until async XCTest teardown, including early returns
    /// and thrown errors. Test targets supply the close operation so this
    /// support target needs no testable import when built in release mode.
    @discardableResult
    func trackAsyncTestResource<Resource: Sendable>(
        _ resource: Resource,
        beforeClosing: @escaping @Sendable () async -> Void = {},
        closing: @escaping @Sendable (Resource) async throws -> Void
    ) -> Resource {
        addTeardownBlock {
            await beforeClosing()
            try await closing(resource)
        }
        return resource
    }

    /// Removes a temporary store only after the later module teardown blocks
    /// have drained jobs and closed its database. Never use for a live store.
    func removeClipboardHistoryDirectoryAfterTest(_ directory: URL) {
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
    }
}
