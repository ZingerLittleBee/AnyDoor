import XCTest
@testable import AnyDoor

final class SyncTimestampTests: XCTestCase {

    func testTotalOrderWallThenCounterThenDevice() {
        let base = SyncTimestamp(wallMillis: 100, counter: 5, deviceID: "b")
        XCTAssertLessThan(base, SyncTimestamp(wallMillis: 101, counter: 0, deviceID: "a"))
        XCTAssertLessThan(base, SyncTimestamp(wallMillis: 100, counter: 6, deviceID: "a"))
        XCTAssertLessThan(base, SyncTimestamp(wallMillis: 100, counter: 5, deviceID: "c"))
        XCTAssertFalse(base < base)
    }

    func testNowIsStrictlyIncreasingEvenWhenWallClockRegresses() {
        var clock = SyncClock(deviceID: "mac-a")
        let walls: [Int64] = [1_000, 1_000, 500, 999, 1_001, 1_001]
        var previous: SyncTimestamp?
        for wall in walls {
            let issued = clock.now(wallMillis: wall)
            if let previous {
                XCTAssertLessThan(previous, issued, "issue at wall \(wall) must outrank the previous issue")
            }
            previous = issued
        }
    }

    func testEditAfterObservingRemoteOutranksIt() {
        var clock = SyncClock(deviceID: "mac-a")
        _ = clock.now(wallMillis: 1_000)
        // Remote device with a wall clock far in our future.
        let remote = SyncTimestamp(wallMillis: 5_000, counter: 3, deviceID: "mac-b")
        clock.observe(remote)
        // Our wall clock still says 1_001, but the next issue must win.
        let issued = clock.now(wallMillis: 1_001)
        XCTAssertLessThan(remote, issued)
    }

    func testObserveOlderRemoteDoesNotRewindClock() {
        var clock = SyncClock(deviceID: "mac-a")
        let before = clock.now(wallMillis: 2_000)
        clock.observe(SyncTimestamp(wallMillis: 100, counter: 9, deviceID: "mac-b"))
        let after = clock.now(wallMillis: 100)
        XCTAssertLessThan(before, after)
    }
}
