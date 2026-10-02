import ClipboardHistory
import XCTest

@testable import AnyDoor

final class ClipboardProvidersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClipboardProvidersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testMonitoringProviderReflectsAndTogglesClipboardPreference() async throws {
        // The provider reads the preference from the same suite the
        // lifecycle writes it to.
        let lifecycle = ClipboardHistoryLifecycle(
            operations: ClipboardHistoryLifecycleOperations(
                status: {
                    ClipboardHistoryStatus(availability: .ready, isMonitoring: false)
                },
                setMonitoring: { command, _ in
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: command == .start
                    )
                },
                legacyMigrationPublicationState: { .notPublished },
                migrate: { _, _ in throw CancellationError() },
                cleanupLegacyPayloads: { _ in throw CancellationError() },
                retryStore: {},
                resetStore: {}
            ),
            defaults: defaults,
            migrationRequest: nil
        )
        let provider = ClipboardMonitoringProvider(
            defaults: defaults,
            lifecycle: lifecycle
        )

        let initial = try await provider.readState()
        XCTAssertTrue(initial)

        try await provider.setState(false)
        XCTAssertFalse(defaults.bool(forKey: ClipboardPreferences.monitoringKey))
        let disabled = try await provider.readState()
        XCTAssertFalse(disabled)

        try await provider.setState(true)
        XCTAssertTrue(defaults.bool(forKey: ClipboardPreferences.monitoringKey))
        let enabled = try await provider.readState()
        XCTAssertTrue(enabled)
    }
}
