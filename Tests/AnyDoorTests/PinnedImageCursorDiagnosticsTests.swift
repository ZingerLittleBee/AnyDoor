import XCTest
@testable import AnyDoor

@MainActor
final class PinnedImageCursorDiagnosticsTests: XCTestCase {
    func testDisabledDiagnosticsDoNotWriteOrEvaluateDetails() {
        var lines: [String] = []
        var evaluations = 0
        let diagnostics = PinnedImageCursorDiagnostics(enabled: false) { lines.append($0) }
        func details() -> String { evaluations += 1; return "details" }
        diagnostics.record(key: "window", signature: "state", details: details())
        XCTAssertTrue(lines.isEmpty)
        XCTAssertEqual(evaluations, 0)
    }

    func testRepeatedStateIsSuppressedButReturningToAnEarlierStateIsRecorded() {
        var lines: [String] = []
        let diagnostics = PinnedImageCursorDiagnostics(enabled: true) { lines.append($0) }
        diagnostics.record(key: "window:mouseMoved", signature: "body", details: "body")
        diagnostics.record(key: "window:mouseMoved", signature: "body", details: "duplicate")
        diagnostics.record(key: "window:mouseMoved", signature: "right", details: "right")
        diagnostics.record(key: "window:mouseMoved", signature: "body", details: "body-again")
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].contains("app cursor stack is NOT the displayed cursor"))
        XCTAssertTrue(lines[1].contains("seq=1 body"))
        XCTAssertTrue(lines[2].contains("seq=2 right"))
        XCTAssertTrue(lines[3].contains("seq=3 body-again"))
    }

    func testSourcesAndWindowsHaveIndependentLastStates() {
        var lines: [String] = []
        let diagnostics = PinnedImageCursorDiagnostics(enabled: true) { lines.append($0) }
        for key in ["1:mouseMoved", "1:cursorUpdate", "2:mouseMoved"] {
            diagnostics.record(key: key, signature: "body", details: key)
        }
        XCTAssertEqual(lines.count, 4)
    }

    func testCapWritesOneMarkerAndNeverEvaluatesFurtherDetails() {
        var lines: [String] = []
        var evaluations = 0
        let diagnostics = PinnedImageCursorDiagnostics(enabled: true, limit: 2) { lines.append($0) }
        func details() -> String { evaluations += 1; return "details" }
        for index in 0..<20 {
            diagnostics.record(key: "window-\(index)", signature: "new", details: details())
        }
        XCTAssertEqual(evaluations, 2)
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.filter { $0.contains("diagnostic limit reached") }.count, 1)
    }
}
