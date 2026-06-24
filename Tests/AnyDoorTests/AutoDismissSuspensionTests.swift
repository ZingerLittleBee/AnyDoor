import XCTest
@testable import AnyDoor

final class AutoDismissSuspensionTests: XCTestCase {
    func testNestedSuspensionsOnlyRearmAfterFinalEnd() {
        var suspension = AutoDismissSuspension()

        XCTAssertFalse(suspension.isActive)
        XCTAssertTrue(suspension.begin())
        XCTAssertTrue(suspension.isActive)
        XCTAssertFalse(suspension.begin())

        XCTAssertEqual(suspension.end(), .stillSuspended)
        XCTAssertTrue(suspension.isActive)

        XCTAssertEqual(suspension.end(), .readyToRearm)
        XCTAssertFalse(suspension.isActive)
    }

    func testResetPreventsStaleEndFromRearming() {
        var suspension = AutoDismissSuspension()

        XCTAssertTrue(suspension.begin())
        suspension.reset()

        XCTAssertFalse(suspension.isActive)
        XCTAssertEqual(suspension.end(), .alreadyIdle)
    }
}
