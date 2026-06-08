import XCTest
@testable import AnyDoor

final class ScheduledShutdownServiceTests: XCTestCase {
    func testDurationSecondsFloorsAtOneMinute() {
        XCTAssertEqual(ScheduledShutdownDuration.minutes(30).seconds, 1800)
        XCTAssertEqual(ScheduledShutdownDuration.minutes(0).seconds, 60)   // floored to 1 min
        XCTAssertEqual(ScheduledShutdownDuration.minutes(-5).seconds, 60)
    }

    func testStateIsArmed() {
        XCTAssertFalse(ScheduledShutdownState.off.isArmed)
        XCTAssertTrue(ScheduledShutdownState.armed(fireDate: Date()).isArmed)
    }
}
