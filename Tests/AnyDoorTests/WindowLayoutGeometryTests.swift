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

    // MARK: - Halves (top/bottom)

    func testTopHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .topHalf, windowFrame: window, visibleFrame: visible
        )
        // floor(875/2) == 437, anchored at the visible top.
        XCTAssertEqual(target, CGRect(x: 0, y: 25, width: 1440, height: 437))
    }

    func testBottomHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .bottomHalf, windowFrame: window, visibleFrame: visible
        )
        // height 437, bottom-anchored: maxY (900) - 437 == 463.
        XCTAssertEqual(target, CGRect(x: 0, y: 463, width: 1440, height: 437))
    }

    func testTopAndBottomHalvesDoNotOverlap() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = WindowLayoutGeometry.targetRect(action: .topHalf, windowFrame: window, visibleFrame: visible)
        let bottom = WindowLayoutGeometry.targetRect(action: .bottomHalf, windowFrame: window, visibleFrame: visible)
        XCTAssertLessThanOrEqual(top.maxY, bottom.minY, "halves must not overlap")
        XCTAssertEqual(top.minY, visible.minY)
        XCTAssertEqual(bottom.maxY, visible.maxY)
    }

    // MARK: - Quarters

    func testTopLeftQuarter() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = WindowLayoutGeometry.targetRect(action: .topLeftQuarter, windowFrame: window, visibleFrame: visible)
        // floor(1440/2)=720, floor(875/2)=437, anchored top-left.
        XCTAssertEqual(target, CGRect(x: 0, y: 25, width: 720, height: 437))
    }

    func testBottomRightQuarterMeetsTopLeft() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tl = WindowLayoutGeometry.targetRect(action: .topLeftQuarter, windowFrame: window, visibleFrame: visible)
        let br = WindowLayoutGeometry.targetRect(action: .bottomRightQuarter, windowFrame: window, visibleFrame: visible)
        // Right column starts at maxX - 720; bottom row starts at maxY - 437.
        XCTAssertEqual(br, CGRect(x: 720, y: 463, width: 720, height: 437))
        XCTAssertLessThanOrEqual(tl.maxX, br.minX, "columns must not overlap")
        XCTAssertLessThanOrEqual(tl.maxY, br.minY, "rows must not overlap")
        XCTAssertEqual(br.maxX, visible.maxX)
        XCTAssertEqual(br.maxY, visible.maxY)
    }

    func testTopRightAndBottomLeftQuarters() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tr = WindowLayoutGeometry.targetRect(action: .topRightQuarter, windowFrame: window, visibleFrame: visible)
        let bl = WindowLayoutGeometry.targetRect(action: .bottomLeftQuarter, windowFrame: window, visibleFrame: visible)
        XCTAssertEqual(tr, CGRect(x: 720, y: 25, width: 720, height: 437))
        XCTAssertEqual(bl, CGRect(x: 0, y: 463, width: 720, height: 437))
    }

    // MARK: - Thirds (tile the full width exactly)

    func testThirdsTileFullWidth() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftThird, windowFrame: window, visibleFrame: visible)
        let center = WindowLayoutGeometry.targetRect(action: .centerThird, windowFrame: window, visibleFrame: visible)
        let right = WindowLayoutGeometry.targetRect(action: .rightThird, windowFrame: window, visibleFrame: visible)
        // floor(1440/3) == 480 each; full height.
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 480, height: 875))
        XCTAssertEqual(right.maxX, visible.maxX)
        // Center fills the gap between left.maxX and right.minX exactly.
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.maxX, right.minX)
        // No gaps, no overlaps across the whole width.
        XCTAssertEqual(left.minX, visible.minX)
    }

    func testThirdsTileNonDivisibleWidth() {
        // 1000 / 3 -> floor 333; center must absorb the remainder so the
        // three columns still cover [0, 1000] with no gap.
        let odd = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftThird, windowFrame: window, visibleFrame: odd)
        let center = WindowLayoutGeometry.targetRect(action: .centerThird, windowFrame: window, visibleFrame: odd)
        let right = WindowLayoutGeometry.targetRect(action: .rightThird, windowFrame: window, visibleFrame: odd)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.maxX, 1000)
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.maxX, right.minX)
        XCTAssertEqual(center.width, 1000 - left.width - right.width)
    }

    // MARK: - Two-thirds

    func testTwoThirds() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftTwoThirds, windowFrame: window, visibleFrame: visible)
        let right = WindowLayoutGeometry.targetRect(action: .rightTwoThirds, windowFrame: window, visibleFrame: visible)
        // floor(1440 * 2 / 3) == 960.
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 960, height: 875))
        XCTAssertEqual(right, CGRect(x: 480, y: 25, width: 960, height: 875))
        XCTAssertEqual(right.maxX, visible.maxX)
    }
}
