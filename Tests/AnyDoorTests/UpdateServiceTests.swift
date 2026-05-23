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

    func testInitAppliesDefaultCheckIntervalToAdapter() {
        let fake = FakeUpdater()
        fake.updateCheckInterval = 7 * 86_400  // any stale value

        _ = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        XCTAssertEqual(fake.updateCheckInterval, UpdateService.defaultCheckInterval, accuracy: 0.5)
    }

    func testRebindResetsAdapterToDefaultCheckInterval() {
        let initial = FakeUpdater()
        let service = UpdateService(adapter: initial, skippedVersionProvider: { nil })

        let replacement = FakeUpdater()
        replacement.updateCheckInterval = 30 * 86_400
        service.rebind(to: replacement)

        XCTAssertEqual(replacement.updateCheckInterval, UpdateService.defaultCheckInterval, accuracy: 0.5)
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

    func testDidFailCheckUpdatesLastCheckDateWithoutClearingBanner() {
        let fake = FakeUpdater()
        let service = UpdateService(adapter: fake, skippedVersionProvider: { nil })

        service.didFindUpdate(version: "1.2.0")
        let originalDate = service.lastCheckDate
        XCTAssertEqual(service.availableVersion, "1.2.0")

        // Sleep briefly so the second date is observably distinct.
        Thread.sleep(forTimeInterval: 0.01)
        service.didFailCheck()

        XCTAssertEqual(service.availableVersion, "1.2.0", "failure must not clear an existing banner")
        XCTAssertNotNil(service.lastCheckDate)
        XCTAssertNotEqual(service.lastCheckDate, originalDate, "failure must update lastCheckDate")
    }
}

@MainActor
private final class FakeUpdater: UpdaterAdapter {
    var automaticallyChecksForUpdates: Bool = true
    var updateCheckInterval: TimeInterval = 86_400
    var checkForUpdatesCallCount: Int = 0
    var checkForUpdatesInBackgroundCallCount: Int = 0

    func checkForUpdates() { checkForUpdatesCallCount += 1 }
    func checkForUpdatesInBackground() { checkForUpdatesInBackgroundCallCount += 1 }
}
