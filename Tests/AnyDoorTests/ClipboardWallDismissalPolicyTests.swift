import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardWallDismissalPolicyTests: XCTestCase {
    func testQuickLookFocusTransferKeepsWallOpen() {
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            isAnimating: false, hasTextWindow: false, hasQuickLook: true
        ))
    }

    func testFocusLossWithoutPreviewDismissesWall() {
        XCTAssertTrue(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            isAnimating: false, hasTextWindow: false, hasQuickLook: false
        ))
    }

    func testTextWindowAndAnimationKeepExistingFocusProtection() {
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            isAnimating: false, hasTextWindow: true, hasQuickLook: false
        ))
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            isAnimating: true, hasTextWindow: false, hasQuickLook: false
        ))
    }

    func testSwitchingToAnotherRegularApplicationDismissesPreviewStack() {
        XCTAssertTrue(dismissesOnActivation(processID: 77))
    }

    func testReturningToOriginalApplicationDoesNotDismissPreviewStack() {
        XCTAssertFalse(dismissesOnActivation(processID: 11))
    }

    func testOpeningFromAnyDoorDoesNotExemptAnEarlierForegroundApplication() {
        XCTAssertTrue(dismissesOnActivation(processID: 11, originalProcessID: nil))
    }

    func testActivatingAnyDoorDoesNotDismissItsPreview() {
        XCTAssertFalse(dismissesOnActivation(processID: 42))
    }

    func testBackgroundHelperActivationDoesNotDismissPreview() {
        XCTAssertFalse(dismissesOnActivation(processID: 77, policy: .accessory))
        XCTAssertFalse(dismissesOnActivation(processID: 77, policy: .prohibited))
    }

    func testActivationObserverIsLimitedToPreviewOutsideAnimations() {
        XCTAssertFalse(dismissesOnActivation(processID: 77, hasQuickLook: false))
        XCTAssertFalse(dismissesOnActivation(processID: 77, isAnimating: true))
    }

    private func dismissesOnActivation(
        processID: pid_t,
        policy: NSApplication.ActivationPolicy = .regular,
        hasQuickLook: Bool = true,
        isAnimating: Bool = false,
        originalProcessID: pid_t? = 11
    ) -> Bool {
        ClipboardWallDismissalPolicy.shouldDismissAfterActivatingApplication(
            hasQuickLook: hasQuickLook,
            isAnimating: isAnimating,
            activatedProcessID: processID,
            currentProcessID: 42,
            originalProcessID: originalProcessID,
            activationPolicy: policy
        )
    }
}
