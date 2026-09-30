import CoreGraphics
import XCTest
@testable import AnyDoor

final class SmartCaptureTargetTests: XCTestCase {
    private let point = CGPoint(x: 50, y: 50)
    private let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let window = CapturableWindow(
        id: 42,
        frame: CGRect(x: 0, y: 0, width: 500, height: 400),
        ownerPID: 123
    )

    func testUsefulContentAndControlRolesAreEligible() {
        for role in ["AXButton", "AXStaticText", "AXTextArea", "AXGroup", "AXScrollArea", "AXWebArea", "AXImage", "AXTable"] {
            XCTAssertTrue(SmartCaptureTargetPolicy.isUsefulAccessibilityRole(role), role)
        }
    }

    func testRootsAndUnknownRolesAreNotRegionTargets() {
        for role in ["AXApplication", "AXSystemWide", "AXWindow", "AXMenuBar", "AXUnknown", "", "VendorPrivateRole"] {
            XCTAssertFalse(SmartCaptureTargetPolicy.isUsefulAccessibilityRole(role), role)
        }
    }

    func testPreservesHitToParentOrderThenAppendsExplicitWindow() {
        let button = target("AXButton", CGRect(x: 40, y: 40, width: 30, height: 20))
        let group = target("AXGroup", CGRect(x: 20, y: 20, width: 200, height: 120))
        let scrollArea = target("AXScrollArea", CGRect(x: 10, y: 10, width: 400, height: 300))

        let result = resolve([button, group, scrollArea])

        XCTAssertEqual(result.targets, [button, group, scrollArea, fallbackTarget])
        XCTAssertNil(result.fallbackReason)
    }

    func testRejectsInvalidNonfiniteZeroNegativeTinyAndNoncontainingFrames() {
        let frames = [
            CGRect.zero,
            CGRect.null,
            CGRect.infinite,
            CGRect(x: CGFloat.nan, y: 10, width: 100, height: 100),
            CGRect(x: 10, y: CGFloat.infinity, width: 100, height: 100),
            CGRect(x: 10, y: 10, width: CGFloat.nan, height: 100),
            CGRect(x: 10, y: 10, width: 100, height: CGFloat.infinity),
            CGRect(x: 40, y: 40, width: 0, height: 100),
            CGRect(x: 40, y: 40, width: 100, height: 0),
            CGRect(x: 100, y: 40, width: -100, height: 100),
            CGRect(x: 40, y: 100, width: 100, height: -100),
            CGRect(x: 48, y: 40, width: 4.9, height: 100),
            CGRect(x: 40, y: 48, width: 100, height: 4.9),
            CGRect(x: 600, y: 20, width: 100, height: 100),
            CGRect(x: 1100, y: 20, width: 100, height: 100),
        ]

        for frame in frames {
            let result = resolve([target("AXGroup", frame)])
            XCTAssertEqual(result.targets, [fallbackTarget], "Unexpected target for \(frame)")
            XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
        }
    }

    func testMinimumFivePointEdgesAreAccepted() {
        let candidate = target("AXButton", CGRect(x: 48, y: 48, width: 5, height: 5))
        XCTAssertEqual(resolve([candidate]).targets, [candidate, fallbackTarget])
    }

    func testDeduplicatesWithinOnePointWithoutReordering() {
        let first = target("AXImage", CGRect(x: 20, y: 20, width: 100, height: 80))
        let duplicate = target("AXGroup", CGRect(x: 21, y: 19, width: 100, height: 80))
        let ancestor = target("AXScrollArea", CGRect(x: 10, y: 10, width: 200, height: 120))

        XCTAssertEqual(resolve([first, duplicate, ancestor, first]).targets, [first, ancestor, fallbackTarget])
    }

    func testMoreThanOnePointDifferenceRetainsDistinctTargets() {
        let first = target("AXStaticText", CGRect(x: 20, y: 20, width: 100, height: 80))
        let second = target("AXGroup", CGRect(x: 18.9, y: 20, width: 101.1, height: 80))
        XCTAssertEqual(resolve([first, second]).targets, [first, second, fallbackTarget])
    }

    func testMalformedParentsCannotShrinkOrReverseHierarchy() {
        let child = target("AXImage", CGRect(x: 20, y: 20, width: 100, height: 80))
        let smallerParent = target("AXGroup", CGRect(x: 30, y: 30, width: 50, height: 40))
        let overlappingParent = target("AXGroup", CGRect(x: 40, y: 40, width: 150, height: 100))
        let shiftedSameSize = target("AXGroup", CGRect(x: 18, y: 20, width: 100, height: 80))
        let realAncestor = target("AXScrollArea", CGRect(x: 10, y: 10, width: 300, height: 200))

        XCTAssertEqual(
            resolve([child, smallerParent, overlappingParent, shiftedSameSize, realAncestor]).targets,
            [child, realAncestor, fallbackTarget]
        )
    }

    func testAncestorContainmentAllowsOnePointRoundingDifference() {
        let child = target("AXImage", CGRect(x: 20, y: 20, width: 100, height: 80))
        let roundedAncestor = target("AXGroup", CGRect(x: 21, y: 10, width: 130, height: 100))
        XCTAssertEqual(resolve([child, roundedAncestor]).targets, [child, roundedAncestor, fallbackTarget])
    }

    func testWindowSizedAccessibilityGeometryDoesNotDuplicateWindowTarget() {
        let group = target("AXGroup", window.frame.insetBy(dx: 0.5, dy: 0.5))
        let axWindow = target("AXWindow", window.frame)
        let spuriousWindow = SmartCaptureTarget(kind: .window(id: 999), globalFrame: window.frame)

        let result = resolve([group, axWindow, spuriousWindow])

        XCTAssertEqual(result.targets, [fallbackTarget])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testPermissionFailureIsExplicitAndKeepsWholeWindowFallback() {
        let candidate = target("AXButton", CGRect(x: 40, y: 40, width: 30, height: 20))
        let result = resolve([candidate], trusted: false)

        XCTAssertEqual(result.targets, [fallbackTarget])
        XCTAssertEqual(result.fallbackReason, .accessibilityPermissionRequired)
    }

    func testEmptyHierarchyFallsBackToWholeWindow() {
        let result = resolve([])
        XCTAssertEqual(result.targets, [fallbackTarget])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testUnsupportedRolesFallBackInsteadOfClaimingSmartGeometry() {
        let result = resolve([target("AXUnknown", CGRect(x: 20, y: 20, width: 100, height: 80))])
        XCTAssertEqual(result.targets, [fallbackTarget])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testMissingWindowCannotProduceUnverifiedAccessibilityTargets() {
        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [target("AXGroup", CGRect(x: 20, y: 20, width: 100, height: 80))],
            at: point,
            screenFrame: screen,
            window: nil,
            accessibilityTrusted: true
        )
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testMissingWindowStillReportsPermissionFailure() {
        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [], at: point, screenFrame: screen, window: nil, accessibilityTrusted: false
        )
        XCTAssertTrue(result.targets.isEmpty)
        XCTAssertEqual(result.fallbackReason, .accessibilityPermissionRequired)
    }

    func testAccessibilityClipsToCurrentDisplayWhileWindowKeepsActualBounds() {
        let display = CGRect(x: -600, y: -200, width: 600, height: 800)
        let spanningWindow = CapturableWindow(id: 8, frame: CGRect(x: -400, y: -100, width: 800, height: 500))
        let candidate = target("AXGroup", CGRect(x: -200, y: -50, width: 400, height: 250))

        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [candidate],
            at: CGPoint(x: -100, y: 50),
            screenFrame: display,
            window: spanningWindow,
            accessibilityTrusted: true
        )

        XCTAssertEqual(result.targets, [
            target("AXGroup", CGRect(x: -200, y: -50, width: 200, height: 250)),
            SmartCaptureTarget(kind: .window(id: 8), globalFrame: spanningWindow.frame),
        ])
        XCTAssertNil(result.fallbackReason)
    }

    func testAccessibilityDoesNotExtendPastSelectedWindow() {
        let candidate = target("AXScrollArea", CGRect(x: -100, y: 20, width: 300, height: 100))
        XCTAssertEqual(resolve([candidate]).targets, [
            target("AXScrollArea", CGRect(x: 0, y: 20, width: 200, height: 100)), fallbackTarget,
        ])
    }

    func testDeduplicationRunsAfterClipping() {
        let first = target("AXImage", CGRect(x: -20, y: 20, width: 120, height: 100))
        let second = target("AXGroup", CGRect(x: -80, y: 20, width: 180, height: 100))
        XCTAssertEqual(resolve([first, second]).targets, [
            target("AXImage", CGRect(x: 0, y: 20, width: 100, height: 100)), fallbackTarget,
        ])
    }

    func testTinyVisibleRemainderFallsBackToWindow() {
        let candidate = target("AXImage", CGRect(x: -50, y: 20, width: 54, height: 100))
        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [candidate], at: CGPoint(x: 2, y: 50), screenFrame: screen,
            window: window, accessibilityTrusted: true
        )
        XCTAssertEqual(result.targets, [fallbackTarget])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testDisplayClippedWindowSizedCandidateStillUsesExplicitWindowFallback() {
        let spanningWindow = CapturableWindow(id: 8, frame: CGRect(x: -400, y: 0, width: 800, height: 500))
        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [target("AXGroup", spanningWindow.frame)], at: point,
            screenFrame: screen, window: spanningWindow, accessibilityTrusted: true
        )
        XCTAssertEqual(result.targets, [SmartCaptureTarget(kind: .window(id: 8), globalFrame: spanningWindow.frame)])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testInvalidDisplayOrPointDoesNotProduceTargets() {
        for display in [CGRect.zero, CGRect.null, CGRect.infinite] {
            let result = SmartCaptureTargetPolicy.resolution(
                candidates: [], at: point, screenFrame: display, window: window, accessibilityTrusted: true
            )
            XCTAssertTrue(result.targets.isEmpty)
        }
        for invalidPoint in [CGPoint(x: CGFloat.nan, y: 50), CGPoint(x: 2000, y: 50)] {
            let result = SmartCaptureTargetPolicy.resolution(
                candidates: [], at: invalidPoint, screenFrame: screen, window: window, accessibilityTrusted: true
            )
            XCTAssertTrue(result.targets.isEmpty)
        }
    }

    func testCapturableWindowOwnerPIDDefaultsToNil() {
        XCTAssertNil(CapturableWindow(id: 1, frame: screen).ownerPID)
        XCTAssertEqual(window.ownerPID, 123)
    }

    func testForegroundWindowKeepsRealOwnProcessWindowAndPreservesFrontToBackOrder() {
        let ownWindow = CapturableWindow(id: 1, frame: screen, ownerPID: 456)
        let backgroundWindow = CapturableWindow(id: 2, frame: screen, ownerPID: 789)
        let selected = SmartCaptureTargetPolicy.foregroundWindow(
            at: point, in: [ownWindow, window, backgroundWindow]
        )
        XCTAssertEqual(selected, ownWindow)
        let result = SmartCaptureTargetPolicy.resolution(
            candidates: [], at: point, screenFrame: screen,
            window: selected, accessibilityTrusted: true
        )
        XCTAssertEqual(result.targets, [SmartCaptureTarget(kind: .window(id: 1), globalFrame: screen)])
        XCTAssertEqual(result.fallbackReason, .noUsefulAccessibilityGeometry)
    }

    func testForegroundWindowRejectsMalformedOrNoncontainingGeometry() {
        let invalid = CapturableWindow(id: 1, frame: .infinite, ownerPID: 456)
        let outside = CapturableWindow(id: 2, frame: CGRect(x: 600, y: 0, width: 100, height: 100), ownerPID: 789)
        XCTAssertNil(SmartCaptureTargetPolicy.foregroundWindow(
            at: point, in: [invalid, outside]
        ))
    }

    func testWindowAndSheetBoundariesRequireMatchingOwnerAndFrame() {
        for role in ["AXWindow", "AXSheet"] {
            XCTAssertTrue(SmartCaptureTargetPolicy.matchesWindowBoundary(
                role: role, globalFrame: window.frame, ownerPID: 123, window: window
            ))
            XCTAssertFalse(SmartCaptureTargetPolicy.matchesWindowBoundary(
                role: role, globalFrame: window.frame, ownerPID: 456, window: window
            ))
            XCTAssertFalse(SmartCaptureTargetPolicy.matchesWindowBoundary(
                role: role, globalFrame: screen, ownerPID: 123, window: window
            ))
        }
        XCTAssertFalse(SmartCaptureTargetPolicy.matchesWindowBoundary(
            role: "AXGroup", globalFrame: window.frame, ownerPID: 123, window: window
        ))
    }

    func testDocumentWindowDoesNotVerifyItsStandaloneSheetButMatchingSheetDoes() {
        let sheet = CapturableWindow(
            id: 99, frame: CGRect(x: 20, y: 20, width: 300, height: 200), ownerPID: 123
        )
        XCTAssertFalse(SmartCaptureTargetPolicy.matchesWindowBoundary(
            role: "AXWindow", globalFrame: window.frame, ownerPID: 123, window: sheet
        ))
        XCTAssertTrue(SmartCaptureTargetPolicy.matchesWindowBoundary(
            role: "AXSheet", globalFrame: sheet.frame, ownerPID: 123, window: sheet
        ))
    }

    private var fallbackTarget: SmartCaptureTarget {
        SmartCaptureTarget(kind: .window(id: window.id), globalFrame: window.frame)
    }

    private func target(_ role: String, _ frame: CGRect) -> SmartCaptureTarget {
        SmartCaptureTarget(kind: .accessibility(role: role), globalFrame: frame)
    }

    private func resolve(_ candidates: [SmartCaptureTarget], trusted: Bool = true) -> SmartCaptureResolution {
        SmartCaptureTargetPolicy.resolution(
            candidates: candidates, at: point, screenFrame: screen,
            window: window, accessibilityTrusted: trusted
        )
    }
}
