import XCTest
import CoreGraphics
@testable import AnyDoor

final class SelectionGeometryTests: XCTestCase {
    func testNormalizedRectFromAnyDragDirection() {
        let r = SelectionGeometry.normalizedRect(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 40, y: 120))
        XCTAssertEqual(r, CGRect(x: 40, y: 80, width: 60, height: 40))
    }

    func testClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = SelectionGeometry.clamped(CGRect(x: -10, y: 150, width: 60, height: 100), to: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 150, width: 50, height: 50))
    }

    func testFormatDimensions() {
        XCTAssertEqual(SelectionGeometry.formatDimensions(CGSize(width: 12.6, height: 40.2)), "13 × 40")
    }

    func testRectIsEmptyBelowMinimum() {
        XCTAssertTrue(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 3, height: 50)))
        XCTAssertFalse(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 6, height: 6)))
    }
}
