import CoreServices
import Foundation
import os
import PluginInterface
import SwiftData
import XCTest
@testable import AnyDoor

/// Scripted stand-in for the Finder Automation check, so no test reaches TCC
/// or Finder. Records whether a check ever ran on the main thread, and can
/// stall checks the way a hung Finder does.
private final class ScriptedAutomationCheck: Sendable {
    private struct State {
        var status: OSStatus
        var ranOnMainThread = false
        var stalled = false
    }

    private let state: OSAllocatedUnfairLock<State>
    /// Holds stalled checks until `release(answering:)`.
    private let gate = DispatchSemaphore(value: 0)

    // `some BinaryInteger`: the SDK imports `noErr` and the Apple Event error
    // constants with different integer types.
    init(_ status: some BinaryInteger) {
        state = OSAllocatedUnfairLock(initialState: State(status: OSStatus(status)))
    }

    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }

    func set(_ newStatus: some BinaryInteger) {
        let newStatus = OSStatus(newStatus)
        state.withLock { $0.status = newStatus }
    }

    /// Later checks block until `release(answering:)`, like a Finder that
    /// stopped answering Apple Events.
    func stall() {
        state.withLock { $0.stalled = true }
    }

    /// Lets stalled checks finish with `newStatus`. Safe to call again.
    func release(answering newStatus: some BinaryInteger) {
        let newStatus = OSStatus(newStatus)
        let wasStalled = state.withLock { state in
            defer { state.stalled = false }
            state.status = newStatus
            return state.stalled
        }
        if wasStalled { gate.signal() }
    }

    func determine() -> OSStatus {
        let onMainThread = Thread.isMainThread
        let stalled = state.withLock { state in
            if onMainThread { state.ranOnMainThread = true }
            return state.stalled
        }
        if stalled {
            gate.wait()
            gate.signal() // Pass the release on to any other stalled check.
        }
        return state.withLock { $0.status }
    }
}

/// Reads `permission` until it reports `expected`, for up to five seconds.
private func eventually(
    _ provider: EmptyTrashProvider,
    reports expected: PermissionStatus
) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await provider.permission == expected { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

final class EmptyTrashProviderTests: XCTestCase {

    func testPermissionFollowsTheLiveFinderAutomationVerdict() async {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        let provider = EmptyTrashProvider(determineAutomationPermission: { check.determine() })

        var permission = await provider.permission
        XCTAssertEqual(permission, .denied)

        // Granted in System Settings: the next read reports it, no run() needed.
        check.set(noErr)
        permission = await provider.permission
        XCTAssertEqual(permission, .granted)

        // Undecided again (a TCC reset): runnable, so a click shows the
        // system prompt instead of sending the user to System Settings.
        check.set(errAEEventWouldRequireUserConsent)
        permission = await provider.permission
        XCTAssertEqual(permission, .undetermined)
    }

    func testCheckWithoutVerdictKeepsTheLastKnownPermission() async {
        let check = ScriptedAutomationCheck(procNotFound)
        let provider = EmptyTrashProvider(determineAutomationPermission: { check.determine() })

        var permission = await provider.permission
        XCTAssertEqual(permission, .undetermined, "nothing is known before the first verdict")

        check.set(errAEEventNotPermitted)
        _ = await provider.permission
        // Finder isn't running, so the check has no verdict: the last one stands.
        check.set(procNotFound)
        permission = await provider.permission
        XCTAssertEqual(permission, .denied)

        check.set(noErr)
        _ = await provider.permission
        check.set(procNotFound)
        permission = await provider.permission
        XCTAssertEqual(permission, .granted)
    }

    /// The check waits for Finder itself, which never answers while it hangs.
    func testUnansweredCheckReportsTheLastVerdictWithinTheTimeout() async {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        addTeardownBlock { check.release(answering: noErr) }
        let provider = EmptyTrashProvider(checkTimeout: .milliseconds(50)) { check.determine() }
        let answered = await eventually(provider, reports: .denied)
        XCTAssertTrue(answered, "Finder answered once before it hangs")

        check.stall()
        for _ in 0..<2 {
            let stalledRead = await boundedPermission(of: provider)
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
        let store = try makePanelStore(
            provider: EmptyTrashProvider(determineAutomationPermission: { check.determine() })
        )

        // Opening the panel refreshes every provider.
        await store.refreshAll()
        XCTAssertEqual(emptyTrashPermission(in: store), .denied)

        // The user grants Finder access in System Settings and reopens the panel.
        check.set(noErr)
        await store.refreshAll()
        XCTAssertEqual(emptyTrashPermission(in: store), .granted)
        XCTAssertFalse(check.ranOnMainThread, "the Apple Event check must stay off the main thread")
    }

    /// Opening the panel or the palette must not wait for a hung Finder.
    @MainActor
    func testRefreshDoesNotWaitForAFinderThatNeverAnswers() async throws {
        let check = ScriptedAutomationCheck(errAEEventNotPermitted)
        addTeardownBlock { check.release(answering: noErr) }
        let provider = EmptyTrashProvider(checkTimeout: .milliseconds(50)) { check.determine() }
        let store = try makePanelStore(provider: provider)
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

    /// Reads `permission`, failing the test instead of hanging when the read
    /// never returns.
    private func boundedPermission(of provider: EmptyTrashProvider) async -> PermissionStatus? {
        let result = OSAllocatedUnfairLock<PermissionStatus?>(initialState: nil)
        let returned = expectation(description: "permission returns")
        Task {
            let permission = await provider.permission
            result.withLock { $0 = permission }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 5)
        return result.withLock { $0 }
    }

    /// A fresh store over an in-memory container holding only the Empty Trash
    /// row, so no test touches `PanelStore.shared` or the seeder's defaults.
    @MainActor
    private func makePanelStore(provider: EmptyTrashProvider) throws -> PanelStore {
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        container.mainContext.insert(BuiltinPreference(itemKey: BuiltinItem.emptyTrash.rawValue))
        try container.mainContext.save()
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [provider])
        return store
    }

    @MainActor
    private func emptyTrashPermission(in store: PanelStore) -> PermissionStatus? {
        store.topLevelEntries.first { $0.source == .builtin(.emptyTrash) }?.permission
    }
}
