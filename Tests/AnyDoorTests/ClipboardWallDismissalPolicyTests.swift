import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardWallDismissalPolicyTests: XCTestCase {
    func testQuickLookFocusTransferKeepsWallOpen() {
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: false, hasQuickLook: true,
            isOpening: false, openedOverAnotherApp: true
        ))
    }

    func testFocusLossWithoutPreviewDismissesWall() {
        XCTAssertTrue(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: false, hasQuickLook: false,
            isOpening: false, openedOverAnotherApp: true
        ))
    }

    /// A slide over another app no longer exempts a focus loss:
    /// `ClipboardWallLifecycle` defers it until the wall is open instead.
    func testTextWindowKeepsExistingFocusProtection() {
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: true, hasQuickLook: false,
            isOpening: false, openedOverAnotherApp: true
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

    /// ⌘-Tab during the slide-in over another app is a switch away. The
    /// lifecycle defers the dismissal until the wall is open.
    func testFocusLossWhileOpeningOverAnotherAppDismissesWall() {
        XCTAssertTrue(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: false, hasQuickLook: false,
            isOpening: true, openedOverAnotherApp: true
        ))
    }

    /// Opened from the command palette or Settings, the wall can lose key
    /// focus to AnyDoor's own focus handoff while it slides in. That must not
    /// close it, but the same loss once it is open still does.
    func testFocusLossWhileOpeningOverAnyDoorKeepsWallOpen() {
        XCTAssertFalse(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: false, hasQuickLook: false,
            isOpening: true, openedOverAnotherApp: false
        ))
        XCTAssertTrue(ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
            hasTextWindow: false, hasQuickLook: false,
            isOpening: false, openedOverAnotherApp: false
        ))
    }

    func testActivationObserverIsLimitedToAnOpenPreview() {
        XCTAssertFalse(dismissesOnActivation(processID: 77, hasQuickLook: false))
    }

    private func dismissesOnActivation(
        processID: pid_t,
        policy: NSApplication.ActivationPolicy = .regular,
        hasQuickLook: Bool = true,
        originalProcessID: pid_t? = 11
    ) -> Bool {
        ClipboardWallDismissalPolicy.shouldDismissAfterActivatingApplication(
            hasQuickLook: hasQuickLook,
            activatedProcessID: processID,
            currentProcessID: 42,
            originalProcessID: originalProcessID,
            activationPolicy: policy
        )
    }
}
