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

    func testHitTestDeterministicWhenHandlesOverlap() {
        // Rect smaller than the handle size makes opposite handles overlap; the
        // fixed allCases order must resolve the center to topLeft deterministically.
        let rect = CGRect(x: 0, y: 0, width: 4, height: 4)
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 2, y: 2), in: rect, handleSize: 16), .handle(.topLeft))
    }

    // MARK: - Handle resize

    func testResizingCornerKeepsOppositeAnchored() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100) // maxX 300, maxY 200
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = SelectionGeometry.resizing(rect, handle: .bottomLeft, to: CGPoint(x: 150, y: 120), in: bounds, minSize: 10)
        XCTAssertEqual(r, CGRect(x: 150, y: 120, width: 150, height: 80))
    }

    func testResizingEnforcesMinSizeAgainstOppositeEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = SelectionGeometry.resizing(rect, handle: .right, to: CGPoint(x: 50, y: 150), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 20, height: 100))
    }

    func testResizingClampsToBounds() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 250, height: 250)
        let r = SelectionGeometry.resizing(rect, handle: .topRight, to: CGPoint(x: 400, y: 400), in: bounds, minSize: 10)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 150, height: 150))
    }

    func testResizingTopEdgeKeepsXFixed() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        // A `.top` drag moves only maxY; x and width must stay put even though the
        // drag point's x is far away.
        let r = SelectionGeometry.resizing(rect, handle: .top, to: CGPoint(x: 999, y: 260), in: bounds, minSize: 10)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 200, height: 160))
    }

    // MARK: - Default + restore

    func testDefaultCenteredRectHalfSize() {
        let r = SelectionGeometry.defaultCenteredRect(in: CGRect(x: 0, y: 0, width: 1000, height: 800), fraction: 0.5)
        XCTAssertEqual(r, CGRect(x: 250, y: 200, width: 500, height: 400))
    }

    func testDefaultCenteredRectWithNegativeOrigin() {
        let r = SelectionGeometry.defaultCenteredRect(in: CGRect(x: -1000, y: 100, width: 800, height: 600), fraction: 0.5)
        XCTAssertEqual(r, CGRect(x: -800, y: 250, width: 400, height: 300))
    }

    func testRestoredRectOnlyWhenCenterOnADisplay() {
        let d1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let d2 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let onD2 = CGRect(x: 1200, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.restoredRect(last: onD2, displays: [d1, d2]), onD2)
        XCTAssertNil(SelectionGeometry.restoredRect(last: CGRect(x: 5000, y: 100, width: 200, height: 100), displays: [d1, d2]))
        XCTAssertNil(SelectionGeometry.restoredRect(last: nil, displays: [d1, d2]))
    }

    // MARK: - initialSelectionRect (shared restore for region + scrolling capture)

    func testInitialSelectionRestoresLastWhenOnDisplay() {
        let d1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let last = CGRect(x: 100, y: 100, width: 300, height: 200)
        let r = SelectionGeometry.initialSelectionRect(last: last, displays: [d1], mouse: CGPoint(x: 10, y: 10))
        XCTAssertEqual(r, last)
    }

    func testInitialSelectionClampsRestoredToItsDisplay() {
        let d1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        // Center (800, 200) lies on d1 but the rect overflows the right edge.
        let last = CGRect(x: 400, y: 100, width: 800, height: 200)
        let r = SelectionGeometry.initialSelectionRect(last: last, displays: [d1], mouse: .zero)
        XCTAssertEqual(r, last.intersection(d1))
        XCTAssertLessThanOrEqual(r.maxX, d1.maxX)
    }

    func testInitialSelectionDefaultsCenteredUnderMouseWhenNoValidLast() {
        let d1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let d2 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let r = SelectionGeometry.initialSelectionRect(last: nil, displays: [d1, d2], mouse: CGPoint(x: 1500, y: 400))
        XCTAssertEqual(r, SelectionGeometry.defaultCenteredRect(in: d2, fraction: 0.5))
    }

    func testInitialSelectionEmptyDisplaysReturnsZero() {
        XCTAssertEqual(SelectionGeometry.initialSelectionRect(last: nil, displays: [], mouse: .zero), .zero)
    }
}
