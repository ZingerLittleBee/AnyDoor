import CoreGraphics
import XCTest
@testable import AnyDoor

final class SmartCaptureSelectionTests: XCTestCase {
    private let control = SmartCaptureTarget(
        kind: .accessibility(role: "AXButton"), globalFrame: CGRect(x: 10, y: 10, width: 60, height: 30)
    )
    private let panel = SmartCaptureTarget(
        kind: .accessibility(role: "AXGroup"), globalFrame: CGRect(x: 0, y: 0, width: 200, height: 200)
    )
    private let window = SmartCaptureTarget(
        kind: .window(id: 1), globalFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
    )

    func testStartsWithoutForcedSelection() {
        let state = SmartCaptureSelection()
        XCTAssertNil(state.selectedTarget)
        XCTAssertNil(state.pressOrigin)
        XCTAssertFalse(state.isDragging)
    }

    func testOnlyUnifiedScreenshotOptsIntoElementHover() {
        XCTAssertEqual(SmartCaptureSelection.hoverMode(
            mode: .region, allowsElementSelection: true, hasRegion: false, isDragging: false
        ), .elements)
        XCTAssertNil(SmartCaptureSelection.hoverMode(
            mode: .region, allowsElementSelection: false, hasRegion: false, isDragging: false
        ), "Scrolling on a display without its restored viewport must stay manual")
        XCTAssertNil(SmartCaptureSelection.hoverMode(
            mode: .region, allowsElementSelection: true, hasRegion: true, isDragging: false
        ))
        XCTAssertNil(SmartCaptureSelection.hoverMode(
            mode: .region, allowsElementSelection: true, hasRegion: false, isDragging: true
        ))
        XCTAssertNil(SmartCaptureSelection.hoverMode(
            mode: .fullscreen, allowsElementSelection: true, hasRegion: false, isDragging: false
        ))
    }

    func testExplicitWindowActionKeepsWindowOnlyHover() {
        XCTAssertEqual(SmartCaptureSelection.hoverMode(
            mode: .window, allowsElementSelection: true, hasRegion: true, isDragging: false
        ), .window)
        XCTAssertEqual(SmartCaptureSelection.hoverMode(
            mode: .window, allowsElementSelection: false, hasRegion: false, isDragging: false
        ), .window)
    }

    func testTabCyclesOutwardAndWrapsDeterministically() {
        var state = SmartCaptureSelection()
        state.update(targets: [control, panel, window])
        XCTAssertEqual(state.selectedTarget, control)
        state.cycle(backwards: false)
        XCTAssertEqual(state.selectedTarget, panel)
        state.cycle(backwards: false)
        XCTAssertEqual(state.selectedTarget, window)
        state.cycle(backwards: false)
        XCTAssertEqual(state.selectedTarget, control)
    }

    func testShiftTabCyclesInwardAndWrapsToWindow() {
        var state = SmartCaptureSelection()
        state.update(targets: [control, panel, window])
        state.cycle(backwards: true)
        XCTAssertEqual(state.selectedTarget, window)
        state.cycle(backwards: true)
        XCTAssertEqual(state.selectedTarget, panel)
        state.cycle(backwards: true)
        XCTAssertEqual(state.selectedTarget, control)
    }

    func testEmptyAndWindowOnlyHierarchyCanCycle() {
        var state = SmartCaptureSelection()
        state.cycle(backwards: true)
        XCTAssertNil(state.selectedTarget)
        state.update(targets: [window])
        state.cycle(backwards: false)
        state.cycle(backwards: true)
        XCTAssertEqual(state.selectedTarget, window)
    }

    func testNewHoverResetsPreviouslyCycledLevel() {
        var state = SmartCaptureSelection()
        state.update(targets: [control, panel, window])
        state.cycle(backwards: true)
        state.update(targets: [panel, window])
        XCTAssertEqual(state.selectedTarget, panel)
        XCTAssertEqual(state.selectedIndex, 0)
        state.update(targets: [])
        XCTAssertNil(state.selectedTarget)
    }

    func testClickCommitsVisibleTargetDespiteLateResolution() {
        var state = SmartCaptureSelection()
        state.update(targets: [control, panel, window])
        state.cycle(backwards: false)
        state.beginPress(at: .zero)
        state.update(targets: [window])
        state.cycle(backwards: false)
        XCTAssertEqual(state.release(), .target(panel))
        XCTAssertEqual(state.release(), .none)
    }

    func testBelowThresholdMovementRemainsClick() {
        var state = SmartCaptureSelection()
        state.update(targets: [control])
        state.beginPress(at: CGPoint(x: 10, y: 20))
        XCTAssertFalse(state.drag(to: CGPoint(x: 12, y: 22)))
        XCTAssertEqual(state.release(), .target(control))
    }

    func testDragAtThresholdOverridesTargetAndCannotSnapBack() {
        var state = SmartCaptureSelection()
        state.update(targets: [control, window])
        state.beginPress(at: .zero)
        XCTAssertTrue(state.drag(to: CGPoint(x: SelectionGeometry.minimumEdge, y: 0)))
        XCTAssertTrue(state.drag(to: .zero))
        XCTAssertNil(state.selectedTarget)
        state.update(targets: [window])
        XCTAssertNil(state.selectedTarget)
        XCTAssertEqual(state.release(), .region)
    }

    func testDragWithoutResolvedTargetStillCreatesRegion() {
        var state = SmartCaptureSelection()
        state.beginPress(at: .zero)
        XCTAssertTrue(state.drag(to: CGPoint(x: -40, y: 20)))
        XCTAssertEqual(state.release(), .region)
    }

    func testReleaseBeyondThresholdOverridesClickWithoutIntermediateDragEvent() {
        var state = SmartCaptureSelection()
        state.update(targets: [control])
        state.beginPress(at: .zero)
        XCTAssertEqual(state.release(at: CGPoint(x: 10, y: 20)), .region)
        XCTAssertNil(state.selectedTarget)
    }

    func testClickWithoutTargetDoesNotInventRectangle() {
        var state = SmartCaptureSelection()
        state.beginPress(at: .zero)
        XCTAssertEqual(state.release(), .none)
    }

    func testResetCancelsPendingPressAndAllowsNextCapture() {
        var state = SmartCaptureSelection()
        state.update(targets: [window])
        state.beginPress(at: .zero)
        state.reset()
        XCTAssertEqual(state.release(), .none)
        XCTAssertFalse(state.drag(to: CGPoint(x: 20, y: 20)))
        state.update(targets: [control])
        state.beginPress(at: .zero)
        XCTAssertEqual(state.release(), .target(control))
    }
}
