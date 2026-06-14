import XCTest
@testable import AnyDoor

final class RecordingPolicyTests: XCTestCase {
    func testFormatElapsedUnderAnHour() {
        XCTAssertEqual(RecordingPolicy.formatElapsed(0), "0:00")
        XCTAssertEqual(RecordingPolicy.formatElapsed(5), "0:05")
        XCTAssertEqual(RecordingPolicy.formatElapsed(65), "1:05")
        XCTAssertEqual(RecordingPolicy.formatElapsed(600), "10:00")
    }

    func testFormatElapsedOverAnHour() {
        XCTAssertEqual(RecordingPolicy.formatElapsed(3661), "1:01:01")
        XCTAssertEqual(RecordingPolicy.formatElapsed(7325), "2:02:05")
    }

    func testFormatElapsedClampsNegative() {
        XCTAssertEqual(RecordingPolicy.formatElapsed(-10), "0:00")
    }

    func testStateTransitions() {
        XCTAssertTrue(RecordingPolicy.canStart(.idle))
        XCTAssertFalse(RecordingPolicy.canStart(.recording))
        XCTAssertTrue(RecordingPolicy.canStop(.recording))
        XCTAssertTrue(RecordingPolicy.canStop(.paused))
        XCTAssertFalse(RecordingPolicy.canStop(.idle))
        XCTAssertTrue(RecordingPolicy.canPause(.recording))
        XCTAssertFalse(RecordingPolicy.canPause(.paused))
        XCTAssertTrue(RecordingPolicy.canResume(.paused))
    }

    func testClampFrameRate() {
        XCTAssertEqual(RecordingPolicy.clampFrameRate(5), 10)
        XCTAssertEqual(RecordingPolicy.clampFrameRate(30), 30)
        XCTAssertEqual(RecordingPolicy.clampFrameRate(120), 60)
    }

    func testFormatFileExtension() {
        XCTAssertEqual(RecordingFormat.mov.fileExtension, "mov")
        XCTAssertEqual(RecordingFormat.mp4.fileExtension, "mp4")
        XCTAssertEqual(RecordingFormat.gif.fileExtension, "gif")
        XCTAssertFalse(RecordingFormat.mov.needsTranscode)
        XCTAssertTrue(RecordingFormat.gif.needsTranscode)
    }
}
