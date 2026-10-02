import ClipboardHistoryTestSupport
import XCTest

@testable import ClipboardHistory

extension XCTestCase {
    /// Register directory cleanup before this close; XCTest teardown is LIFO.
    @discardableResult
    func trackClipboardHistoryModule(
        _ module: ClipboardHistoryModule,
        beforeClosing: @escaping @Sendable () async -> Void = {}
    ) -> ClipboardHistoryModule {
        trackAsyncTestResource(module, beforeClosing: beforeClosing) {
            try await $0.closeStoreForTesting()
        }
    }
}
