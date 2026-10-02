import CoreServices
import Foundation
import PluginInterface
import XCTest
@testable import AnyDoor

/// Reads `permission` until it reports `expected`, for up to five seconds.
private func eventually(
    _ provider: EmptyTrashProvider,
    reports expected: PermissionStatus
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if (try? await boundedPermission(of: provider)) == expected { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

final class EmptyTrashProviderTests: XCTestCase {

    func testPermissionFollowsTheLiveFinderAutomationVerdict() async throws {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        let provider = EmptyTrashProvider(determineAutomationPermission: { check.determine() })

        var permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .denied)

        // Granted in System Settings: the next read reports it, no run() needed.
        check.set(noErr)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .granted)

        // Undecided again (a TCC reset): runnable, so a click shows the
        // system prompt instead of sending the user to System Settings.
        check.set(errAEEventWouldRequireUserConsent)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .undetermined)
    }

    func testCheckWithoutVerdictKeepsTheLastKnownPermission() async throws {
        let check = ScriptedAutomationCheck(procNotFound)
        let provider = EmptyTrashProvider(determineAutomationPermission: { check.determine() })

        var permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .undetermined, "nothing is known before the first verdict")

        check.set(errAEEventNotPermitted)
        _ = try await boundedPermission(of: provider)
        // Finder isn't running, so the check has no verdict: the last one stands.
        check.set(procNotFound)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .denied)

        check.set(noErr)
        _ = try await boundedPermission(of: provider)
        check.set(procNotFound)
        permission = try await boundedPermission(of: provider)
        XCTAssertEqual(permission, .granted)
    }

    /// The check waits for Finder itself, which never answers while it hangs.
    func testUnansweredCheckReportsTheLastVerdictWithinTheTimeout() async throws {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        addTeardownBlock { check.release(answering: noErr) }
        let provider = EmptyTrashProvider(checkTimeout: .milliseconds(50)) { check.determine() }
        let answered = await eventually(provider, reports: .denied)
        XCTAssertTrue(answered, "Finder answered once before it hangs")

        check.stall()
        for _ in 0..<2 {
            let stalledRead = try await boundedPermission(of: provider)
            XCTAssertEqual(stalledRead, .denied, "the last verdict stands while Finder doesn't answer")
        }

        // Finder answers again, with access granted in the meantime.
        check.release(answering: noErr)
        let recovered = await eventually(provider, reports: .granted)
        XCTAssertTrue(recovered, "the answer reaches the next reads once Finder answers")

        // Later changes still get through: the stalled check doesn't linger.
        check.set(errAEEventNotPermitted)
        let revoked = await eventually(provider, reports: .denied)
        XCTAssertTrue(revoked, "a fresh check runs after the stalled one finishes")
    }

    /// The reported loop: a denied row only opens System Settings and never
    /// runs the action, so the grant has to show up on the next panel open by
    /// itself.
    @MainActor
    func testDeniedRowRecoversOnTheNextRefreshAfterTheGrant() async throws {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        let store = try makeAutomationTestPanelStore(
            provider: EmptyTrashProvider(determineAutomationPermission: { check.determine() })
        )

        // Opening the panel refreshes every provider.
        try await boundedRefresh(store)
        XCTAssertEqual(emptyTrashPermission(in: store), .denied)

        // The user grants Finder access in System Settings and reopens the panel.
        check.set(noErr)
        try await boundedRefresh(store)
        XCTAssertEqual(emptyTrashPermission(in: store), .granted)
        XCTAssertFalse(check.ranOnMainThread, "the Apple Event check must stay off the main thread")
    }

    /// Opening the panel or the palette must not wait for a hung Finder.
    @MainActor
    func testRefreshDoesNotWaitForAFinderThatNeverAnswers() async throws {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        addTeardownBlock { check.release(answering: noErr) }
        let provider = EmptyTrashProvider(checkTimeout: .milliseconds(50)) { check.determine() }
        let store = try makeAutomationTestPanelStore(provider: provider)
        let answered = await eventually(provider, reports: .denied)
        XCTAssertTrue(answered, "Finder answered once before it hangs")

        check.stall()
        let refreshed = expectation(description: "refreshAll returns while Finder doesn't answer")
        Task { @MainActor in
            await store.refreshAll()
            refreshed.fulfill()
        }
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(emptyTrashPermission(in: store), .denied, "the row keeps the last verdict")
    }

    // MARK: - Helpers

    @MainActor
    private func emptyTrashPermission(in store: PanelStore) -> PermissionStatus? {
        store.topLevelEntries.first { $0.source == .builtin(.emptyTrash) }?.permission
    }
}
