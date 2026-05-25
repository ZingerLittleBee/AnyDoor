import XCTest
@testable import AnyDoor

/// Pure-function tests for `WindowLayoutGeometry.targetRect`.
///
/// Inputs are plain `CGRect`s in AX (top-left origin) coordinates; no
/// Accessibility API or NSScreen access. The geometry layer is the only
/// piece of the layout pipeline that is unit-tested — the AX bridge
/// (`WindowLayoutService`) requires real focused windows and is exercised
/// manually.
final class WindowLayoutGeometryTests: XCTestCase {

    // A simple primary-display visible region, top-left at (0,25) to mimic
    // a 25pt menu bar above the visible area.
    private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    func testLeftHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .leftHalf, windowFrame: window, visibleFrame: visible
        )
        XCTAssertEqual(target, CGRect(x: 0, y: 25, width: 720, height: 875))
    }

    func testRightHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .rightHalf, windowFrame: window, visibleFrame: visible
        )
        XCTAssertEqual(target, CGRect(x: 720, y: 25, width: 720, height: 875))
    }

    func testMaximize() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .maximize, windowFrame: window, visibleFrame: visible
        )
        XCTAssertEqual(target, visible)
    }

    func testCenterPreservesWindowSize() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .center, windowFrame: window, visibleFrame: visible
        )
        // Window 400x300 inside 1440x875 visible at origin (0,25):
        // x = 0 + (1440 - 400) / 2 = 520
        // y = 25 + (875 - 300) / 2 = 312.5
        XCTAssertEqual(target.width, 400)
        XCTAssertEqual(target.height, 300)
        XCTAssertEqual(target.minX, 520)
        XCTAssertEqual(target.minY, 312.5)
    }

    func testCenterClampsOversizedWindow() {
        // Window taller and wider than the visible region — center must clamp
        // both dimensions to visibleFrame size and place the window flush
        // with the visible region's top-left.
        let window = CGRect(x: -200, y: -200, width: 2000, height: 1500)
        let target = WindowLayoutGeometry.targetRect(
            action: .center, windowFrame: window, visibleFrame: visible
        )
        XCTAssertEqual(target, visible)
    }

    func testOddVisibleWidthIsStableAcrossLeftAndRight() {
        // Odd width: floor(1001/2) == 500. Both halves get equal 500-wide
        // rects, leaving a 1pt gutter the user won't notice — but the
        // result must be deterministic.
        let oddVisible = CGRect(x: 0, y: 0, width: 1001, height: 800)
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(
            action: .leftHalf, windowFrame: window, visibleFrame: oddVisible
        )
        let right = WindowLayoutGeometry.targetRect(
            action: .rightHalf, windowFrame: window, visibleFrame: oddVisible
        )
        XCTAssertEqual(left.width, 500)
        XCTAssertEqual(right.width, 500)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.maxX, 1001)
    }

    func testFractionalVisibleFrameRoundsConsistently() {
        // Notch displays expose visibleFrame heights with .5pt fractions.
        // Result must be deterministic and the two halves must not overlap.
        let frac = CGRect(x: 0.5, y: 24.5, width: 1440.5, height: 874.5)
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let left = WindowLayoutGeometry.targetRect(
            action: .leftHalf, windowFrame: window, visibleFrame: frac
        )
        let right = WindowLayoutGeometry.targetRect(
            action: .rightHalf, windowFrame: window, visibleFrame: frac
        )
        XCTAssertEqual(left.minX, frac.minX)
        XCTAssertEqual(left.minY, frac.minY)
        XCTAssertEqual(left.height, frac.height)
        XCTAssertEqual(right.maxX, frac.maxX)
        XCTAssertLessThanOrEqual(left.maxX, right.minX,
                                 "halves must not overlap on fractional widths")
    }

    func testCenterWithExactlyVisibleSizedWindow() {
        // Edge case: window already exactly matches visibleFrame. Center
        // must be a no-op (or produce the same rect).
        let window = visible
        let target = WindowLayoutGeometry.targetRect(
            action: .center, windowFrame: window, visibleFrame: visible
        )
        XCTAssertEqual(target, visible)
    }
}
