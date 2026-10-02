import CoreServices
import os
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
        let count = OnboardingStep.allCases.count
        var nav = OnboardingNavigation(stepCount: count)

        // Cannot step before the first page.
        nav.back()
        XCTAssertEqual(nav.index, 0)

        for _ in 0..<(count + 10) { nav.next() }
        XCTAssertEqual(nav.index, count - 1)
        XCTAssertTrue(nav.isLast)
        XCTAssertEqual(nav.current, .customize)

        nav.back()
        XCTAssertEqual(nav.index, count - 2)
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

    // MARK: Permission status mapping

    func test_permissionSnapshot_defaultsToNotGranted() {
        let snap = OnboardingPermissionSnapshot()
        for kind in OnboardingPermissionKind.allCases {
            XCTAssertFalse(snap.isGranted(kind))
        }
    }

    func test_permissionSnapshot_mapsEachKindIndependently() {
        var snap = OnboardingPermissionSnapshot()
        snap.accessibility = true

        XCTAssertTrue(snap.isGranted(.accessibility))
        XCTAssertFalse(snap.isGranted(.screenRecording))
        XCTAssertFalse(snap.isGranted(.automation))
    }

    func test_permissionSnapshot_allKindsGranted() {
        let snap = OnboardingPermissionSnapshot(accessibility: true, screenRecording: true, automation: true)
        XCTAssertTrue(OnboardingPermissionKind.allCases.allSatisfy { snap.isGranted($0) })
    }

    /// The permissions step polls every second from the main actor. A check
    /// on the main thread would freeze AnyDoor for as long as System Events
    /// doesn't answer.
    @MainActor
    func test_permissionSnapshot_readKeepsChecksOffTheMainThread() async throws {
        let mainThreadChecks = OSAllocatedUnfairLock(initialState: 0)
        let systemEvents = ScriptedAutomationCheck(noErr)
        addTeardownBlock { systemEvents.release(answering: noErr) }
        let automation = AutomationPermissionCheck(
            target: "test.systemevents",
            timeout: .milliseconds(50),
            determine: { systemEvents.determine() }
        )
        await automation.record(.granted)
        systemEvents.stall()

        let snapshot = try await bounded(within: 5) { @MainActor in
            await OnboardingPermissionSnapshot.read(
                accessibility: {
                    if Thread.isMainThread { mainThreadChecks.withLock { $0 += 1 } }
                    return true
                },
                screenRecording: {
                    if Thread.isMainThread { mainThreadChecks.withLock { $0 += 1 } }
                    return false
                },
                automation: automation
            )
        }

        XCTAssertEqual(
            snapshot,
            OnboardingPermissionSnapshot(accessibility: true, screenRecording: false, automation: true),
            "a System Events that doesn't answer leaves its last verdict"
        )
        XCTAssertEqual(mainThreadChecks.withLock { $0 }, 0, "no permission check runs on the main thread")
        await waitUntil("the Automation check reaches System Events") { systemEvents.entries == 1 }
        XCTAssertFalse(systemEvents.ranOnMainThread, "the Apple Event check must stay off the main thread")
    }

    // MARK: Step catalog sanity

    func test_steps_areOrderedAndDistinct() {
        let steps = OnboardingStep.allCases
        XCTAssertEqual(steps.count, 8)
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
