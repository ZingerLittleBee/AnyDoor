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

    // MARK: - Nudge (move)

    func testMovedWithinBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = SelectionGeometry.moved(CGRect(x: 50, y: 50, width: 30, height: 20), dx: 10, dy: -5, in: bounds)
        XCTAssertEqual(r, CGRect(x: 60, y: 45, width: 30, height: 20))
    }

    func testMovedClampsAtEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = SelectionGeometry.moved(CGRect(x: 80, y: 0, width: 30, height: 20), dx: 50, dy: -50, in: bounds)
        // x clamps to maxX-width=70, y clamps to minY=0
        XCTAssertEqual(r, CGRect(x: 70, y: 0, width: 30, height: 20))
    }

    // MARK: - Resize

    func testResizedGrows() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = SelectionGeometry.resized(CGRect(x: 10, y: 10, width: 40, height: 30), dw: 10, dh: 5, in: bounds)
        XCTAssertEqual(r, CGRect(x: 10, y: 10, width: 50, height: 35))
    }

    func testResizedClampsToMinimum() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = SelectionGeometry.resized(CGRect(x: 0, y: 0, width: 6, height: 6), dw: -100, dh: -100, in: bounds)
        XCTAssertEqual(r.width, SelectionGeometry.minimumEdge)
        XCTAssertEqual(r.height, SelectionGeometry.minimumEdge)
    }

    func testResizedClampsToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let r = SelectionGeometry.resized(CGRect(x: 80, y: 80, width: 10, height: 10), dw: 100, dh: 100, in: bounds)
        XCTAssertEqual(r, CGRect(x: 80, y: 80, width: 20, height: 20))
    }

    // MARK: - Loupe placement

    func testLoupeOffsetLowerRightByDefault() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = SelectionGeometry.loupeFrame(near: CGPoint(x: 500, y: 500), loupeSize: 120, gap: 16, in: bounds)
        XCTAssertEqual(r, CGRect(x: 516, y: 364, width: 120, height: 120))
    }

    func testLoupeFlipsNearRightAndBottomEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        let r = SelectionGeometry.loupeFrame(near: CGPoint(x: 590, y: 10), loupeSize: 120, gap: 16, in: bounds)
        // near right edge -> flips left of cursor; near bottom -> flips above cursor, then clamps on-screen
        XCTAssertGreaterThanOrEqual(r.minX, bounds.minX)
        XCTAssertLessThanOrEqual(r.maxX, bounds.maxX)
        XCTAssertGreaterThanOrEqual(r.minY, bounds.minY)
        XCTAssertLessThanOrEqual(r.maxY, bounds.maxY)
        XCTAssertLessThan(r.minX, 590) // placed to the left of the cursor
    }

    // MARK: - Handles

    func testHandleRectsCenteredOnCornersAndEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100) // maxX 300, maxY 200, mid (200,150)
        let h = SelectionGeometry.handleRects(for: rect, handleSize: 10)
        XCTAssertEqual(h.count, 8)
        XCTAssertEqual(h[.topLeft], CGRect(x: 95, y: 195, width: 10, height: 10))
        XCTAssertEqual(h[.bottomRight], CGRect(x: 295, y: 95, width: 10, height: 10))
        XCTAssertEqual(h[.right], CGRect(x: 295, y: 145, width: 10, height: 10))
        XCTAssertEqual(h[.top], CGRect(x: 195, y: 195, width: 10, height: 10))
    }

    func testHitTestPrioritizesHandlesThenInsideThenOutside() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 100, y: 200), in: rect, handleSize: 16), .handle(.topLeft))
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 200, y: 150), in: rect, handleSize: 16), .inside)
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 10, y: 10), in: rect, handleSize: 16), .outside)
    }
}
