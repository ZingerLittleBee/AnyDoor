import XCTest
@testable import AnyDoor

@MainActor
final class UpdateServiceTests: XCTestCase {

    func testAutomaticChecksTogglePersistsThroughAdapter() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.automaticChecksEnabled = false
        XCTAssertFalse(fake.automaticallyChecksForUpdates)

        service.automaticChecksEnabled = true
        XCTAssertTrue(fake.automaticallyChecksForUpdates)
    }

    func testCheckIntervalDaysMapsToSeconds() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkIntervalDays = 7
        XCTAssertEqual(fake.updateCheckInterval, 7 * 86_400, accuracy: 0.5)

        service.checkIntervalDays = 1
        XCTAssertEqual(fake.updateCheckInterval, 86_400, accuracy: 0.5)
    }

    func testCheckForUpdatesForwardsToAdapter() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkForUpdates()
        XCTAssertEqual(fake.checkForUpdatesCallCount, 1)
    }

    func testFoundUpdatePopulatesAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        XCTAssertEqual(service.availableVersion, "1.2.0")
    }

    func testSkippedVersionIsSuppressedFromBanner() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { "1.2.0" })

        service.didFindUpdate(version: "1.2.0")
        XCTAssertNil(service.availableVersion, "skipped version must not show banner")
    }

    func testNewerVersionAfterSkipStillSurfaces() {
        let fake = FakeUpdater()
        var skipped: String? = "1.2.0"
        let service = UpdateService(adapter: fake, skippedVersionProvider: { skipped })

        service.didFindUpdate(version: "1.2.1")
        XCTAssertEqual(service.availableVersion, "1.2.1")

        // After the user later skips 1.2.1 as well, the banner clears on next check.
        skipped = "1.2.1"
        service.didFindUpdate(version: "1.2.1")
        XCTAssertNil(service.availableVersion)
    }

    func testDismissBannerForThisSessionClearsAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        service.dismissBannerForThisSession()
        XCTAssertNil(service.availableVersion)
    }

    func testNoUpdateFoundClearsAvailableVersion() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        service.didNotFindUpdate()
        XCTAssertNil(service.availableVersion)
    }

    func testCheckingStartedSetsIsCheckingForUpdate() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkingStarted()
        XCTAssertTrue(service.isCheckingForUpdate)
    }

    func testCheckingFinishedClearsIsCheckingForUpdate() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.checkingStarted()
        service.checkingFinished()
        XCTAssertFalse(service.isCheckingForUpdate)
    }
}

@MainActor
private final class FakeUpdater: UpdaterAdapter {
    var automaticallyChecksForUpdates: Bool = true
    var updateCheckInterval: TimeInterval = 86_400
    var lastUpdateCheckDate: Date? = nil
    var checkForUpdatesCallCount: Int = 0
    var checkForUpdatesInBackgroundCallCount: Int = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
