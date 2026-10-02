import CoreServices
import Foundation
import os
import PluginInterface
import SwiftData
@testable import AnyDoor

/// Scripted stand-in for the target app of an Automation check (Finder or
/// System Events), so no test reaches TCC or the real app. It answers
/// `procNotFound` while the target isn't running, counts the checks that reach
/// it and the launches, records whether a check ever ran on the main thread,
/// and can stall checks the way a hung app does.
final class ScriptedAutomationCheck: Sendable {
    private struct State {
        var status: OSStatus
        var isRunning: Bool
        var entries = 0
        var launches = 0
        var ranOnMainThread = false
        /// Holds stalled checks until `release(answering:)` leaves it.
        var stall: DispatchGroup?
    }

    private let state: OSAllocatedUnfairLock<State>

    // `some BinaryInteger`: the SDK imports `noErr` and the Apple Event error
    // constants with different integer types.
    init(_ status: some BinaryInteger, isRunning: Bool = true) {
        state = OSAllocatedUnfairLock(
            initialState: State(status: OSStatus(status), isRunning: isRunning)
        )
    }

    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }

    /// Checks that reached the target so far, stalled ones included.
    var entries: Int { state.withLock { $0.entries } }

    /// Times `launch()` started the target.
    var launches: Int { state.withLock { $0.launches } }

    func set(_ newStatus: some BinaryInteger) {
        let newStatus = OSStatus(newStatus)
        state.withLock { $0.status = newStatus }
    }

    /// Starts the target, as a check's launcher does.
    func launch() {
        state.withLock { state in
            state.isRunning = true
            state.launches += 1
        }
    }

    /// Quits the target, as System Events does when idle.
    func quit() {
        state.withLock { $0.isRunning = false }
    }

    /// Later checks block until `release(answering:)`, like an app that
    /// stopped answering Apple Events.
    func stall() {
        state.withLock { state in
            guard state.stall == nil else { return }
            let stall = DispatchGroup()
            stall.enter()
            state.stall = stall
        }
    }

    /// Lets the stalled checks finish with `newStatus`. Later checks answer at
    /// once until the next `stall()`, which blocks them again. Safe to call
    /// again.
    func release(answering newStatus: some BinaryInteger) {
        let newStatus = OSStatus(newStatus)
        let stall = state.withLock { state in
            defer { state.stall = nil }
            state.status = newStatus
            return state.stall
        }
        stall?.leave()
    }

    func determine() -> OSStatus {
        let onMainThread = Thread.isMainThread
        let stall = state.withLock { state in
            state.entries += 1
            if onMainThread { state.ranOnMainThread = true }
            return state.stall
        }
        stall?.wait()
        return state.withLock { $0.isRunning ? $0.status : OSStatus(procNotFound) }
    }
}

/// Reads `check.status`, failing the test instead of hanging if a regression
/// leaves the read parked for good.
func boundedStatus(
    of check: AutomationPermissionCheck,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> PermissionStatus {
    try await bounded(within: 5, file: file, line: line) { await check.status }
}

/// Reads `provider.permission`, bounded like `boundedStatus(of:)`.
func boundedPermission(
    of provider: some BuiltinProvider,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> PermissionStatus {
    try await bounded(within: 5, file: file, line: line) { await provider.permission }
}

/// Refreshes `store`, bounded like `boundedStatus(of:)`.
func boundedRefresh(
    _ store: PanelStore,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws {
    try await bounded(within: 5, file: file, line: line) { await store.refreshAll() }
}

/// A fresh store over an in-memory container holding only `provider`'s row, so
/// no test touches `PanelStore.shared` or the seeder's defaults.
@MainActor
func makeAutomationTestPanelStore(provider: any BuiltinProvider) throws -> PanelStore {
    let container = try ModelContainer(
        for: KeyBinding.self, BuiltinPreference.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    container.mainContext.insert(BuiltinPreference(itemKey: provider.itemKey.rawValue))
    try container.mainContext.save()
    let store = PanelStore()
    store.bootstrap(modelContainer: container, providers: [provider])
    return store
}
