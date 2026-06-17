import XCTest
@testable import AnyDoor

final class OnboardingTests: XCTestCase {

    // MARK: Completion / skip persistence

    func test_onboardingState_defaultsToIncomplete() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(OnboardingState.hasCompleted(in: defaults))
    }

    func test_onboardingState_persistsCompletion() {
        let (defaults, suite) = makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        OnboardingState.markCompleted(in: defaults)
        XCTAssertTrue(OnboardingState.hasCompleted(in: defaults))

        // Idempotent — marking again keeps it complete (Done / Skip / close all
        // route through the same marker).
        OnboardingState.markCompleted(in: defaults)
        XCTAssertTrue(OnboardingState.hasCompleted(in: defaults))
    }

    // MARK: Navigation / step state

    func test_navigation_startsAtFirstStep() {
        let nav = OnboardingNavigation(stepCount: 6)
        XCTAssertEqual(nav.index, 0)
        XCTAssertTrue(nav.isFirst)
        XCTAssertFalse(nav.isLast)
        XCTAssertEqual(nav.current, .menuBar)
    }

    func test_navigation_advancesAndClampsAtBounds() {
        var nav = OnboardingNavigation(stepCount: 6)

        // Cannot step before the first page.
        nav.back()
        XCTAssertEqual(nav.index, 0)

        for _ in 0..<10 { nav.next() }
        XCTAssertEqual(nav.index, 5)
        XCTAssertTrue(nav.isLast)
        XCTAssertEqual(nav.current, .customize)

        nav.back()
        XCTAssertEqual(nav.index, 4)
        XCTAssertFalse(nav.isLast)
    }

    func test_navigation_goJumpsToStep() {
        var nav = OnboardingNavigation()
        nav.go(to: .capture)
        XCTAssertEqual(nav.current, .capture)
        XCTAssertEqual(nav.index, OnboardingStep.capture.rawValue)
    }

    func test_navigation_initClampsOutOfRangeIndex() {
        XCTAssertEqual(OnboardingNavigation(stepCount: 6, index: 99).index, 5)
        XCTAssertEqual(OnboardingNavigation(stepCount: 6, index: -3).index, 0)
        // A degenerate count never produces an invalid state.
        XCTAssertEqual(OnboardingNavigation(stepCount: 0).stepCount, 1)
    }

    func test_navigation_progressSpansZeroToOne() {
        var nav = OnboardingNavigation(stepCount: 6)
        XCTAssertEqual(nav.progress, 0, accuracy: 0.0001)
        nav.go(to: .customize)
        XCTAssertEqual(nav.progress, 1, accuracy: 0.0001)
    }

    // MARK: Permission status mapping

    func test_permissionSnapshot_defaultsToNeedsAction() {
        let snap = OnboardingPermissionSnapshot()
        for kind in OnboardingPermissionKind.allCases {
            XCTAssertEqual(snap.state(for: kind), .needsAction)
        }
        XCTAssertEqual(snap.grantedCount, 0)
        XCTAssertFalse(snap.allGranted)
    }

    func test_permissionSnapshot_mapsEachKindIndependently() {
        var snap = OnboardingPermissionSnapshot()
        snap.accessibility = true

        XCTAssertEqual(snap.state(for: .accessibility), .granted)
        XCTAssertEqual(snap.state(for: .screenRecording), .needsAction)
        XCTAssertEqual(snap.state(for: .automation), .needsAction)
        XCTAssertEqual(snap.grantedCount, 1)
        XCTAssertFalse(snap.allGranted)
    }

    func test_permissionSnapshot_allGranted() {
        let snap = OnboardingPermissionSnapshot(accessibility: true, screenRecording: true, automation: true)
        XCTAssertTrue(snap.allGranted)
        XCTAssertEqual(snap.grantedCount, 3)
        XCTAssertTrue(OnboardingPermissionKind.allCases.allSatisfy { snap.state(for: $0) == .granted })
    }

    // MARK: Step catalog sanity

    func test_steps_areOrderedAndDistinct() {
        let steps = OnboardingStep.allCases
        XCTAssertEqual(steps.count, 6)
        // rawValue is the page index, in order.
        XCTAssertEqual(steps.map(\.rawValue), Array(0..<steps.count))
        // Every step has a distinct title and sidebar label key.
        XCTAssertEqual(Set(steps.map(\.titleKey)).count, steps.count)
        XCTAssertEqual(Set(steps.map(\.sidebarTitleKey)).count, steps.count)
    }

    // MARK: Helpers

    private func makeEphemeralDefaults() -> (UserDefaults, String) {
        let suite = "test.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}
