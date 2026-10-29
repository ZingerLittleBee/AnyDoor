import CloudKit
import Foundation
import os
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryResetRetryTests: XCTestCase {
    func testPendingResetPermanentFailurePausesAutomaticRequestsAcrossRestartUntilExplicitRetry() async throws {
        let cases: [(CKError.Code, ResetRetryFaultBoundary, ClipboardHistorySyncPhase)] = [
            (.serverRejectedRequest, .transition, .failed(.providerRejected)),
            (.incompatibleVersion, .clear, .failed(.unsupportedVersion)),
        ]
        for (code, boundary, expected) in cases {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-retry-\(UUID())")
            removeClipboardHistoryDirectoryAfterTest(root)
            let cloud = ResetRetryCloud()
            let keys = ResetRetryKeys()
            let first = makeModule(root: root, cloud: cloud, keys: keys)
            let local = try await first.capture(.init(source: .unknown, content: .text("retained during reset")))
            try await first.setSyncEnabled(true)
            let ready = await first.syncStatus()
            XCTAssertEqual(ready.phase, .upToDate)
            let confirmation = try await first.prepareCloudReset()
            let native = ClipboardSyncCloudKit(recordReader: { _, _, _ in throw CKError(code) })
            await cloud.rejectReset(at: boundary, using: native)
            try await first.clearCloudDataAndStopSync(confirmation)
            let failed = await first.syncStatus()
            XCTAssertFalse(failed.isEnabled)
            XCTAssertEqual(failed.cloudReset?.failure, expected)
            XCTAssertTrue(failed.cloudReset?.isPending == true)
            let requests = await cloud.requestCount()

            try await Task.sleep(for: .milliseconds(160))
            await first.resumeSync()
            let automaticRequests = await cloud.requestCount()
            XCTAssertEqual(automaticRequests, requests, "Polling and resume must not retry a permanently rejected reset")
            try await first.closeStoreForTesting()
            let reopened = makeModule(root: root, cloud: cloud, keys: keys)
            await reopened.resumeSync()
            try await Task.sleep(for: .milliseconds(160))
            let reopenedRequests = await cloud.requestCount()
            XCTAssertEqual(reopenedRequests, requests, "The pending reset failure must survive a real store reopen")
            let restored = await reopened.syncStatus()
            XCTAssertFalse(restored.isEnabled)
            XCTAssertEqual(restored.cloudReset?.failure, expected)
            let retained = try await reopened.page(.init())
            XCTAssertEqual(retained.entries.map(\.id), [local.entryID])

            await cloud.allowReset()
            await reopened.retrySync()
            let completed = await reopened.syncStatus()
            XCTAssertFalse(completed.isEnabled)
            XCTAssertEqual(completed.cloudReset?.stage, .completed)
            let recoveredRequests = await cloud.requestCount()
            XCTAssertGreaterThan(recoveredRequests, reopenedRequests)
            let after = try await reopened.page(.init())
            XCTAssertEqual(after.entries.map(\.id), [local.entryID])
        }
    }

    func testDormantPermanentResetAllowsNewAccountActivationButRequiresRetryWhenRediscovered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-account-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = ResetRetryCloud()
        let module = makeModule(root: root, cloud: cloud, keys: ResetRetryKeys())
        let local = try await module.capture(.init(source: .unknown, content: .text("retained across accounts")))
        try await module.setSyncEnabled(true)
        let confirmation = try await module.prepareCloudReset()
        await cloud.rejectReset(at: .transition, using: ClipboardSyncCloudKit(recordReader: { _, _, _ in
            throw CKError(.serverRejectedRequest)
        }))
        try await module.clearCloudDataAndStopSync(confirmation)
        let oldAttempts = await cloud.resetRequestCount()

        await cloud.switchAccount(to: "new-owner")
        try await module.setSyncEnabled(true)
        let active = await module.syncStatus()
        XCTAssertTrue(active.isEnabled)
        XCTAssertEqual(active.phase, .upToDate, "A dormant rejected reset cannot prevent explicitly activating another account")
        XCTAssertNil(active.cloudReset)
        let newAccountAttempts = await cloud.resetRequestCount()
        XCTAssertEqual(newAccountAttempts, oldAttempts, "New-account activation must not execute the old reset")

        await cloud.switchAccount(to: "reset-owner")
        await module.resumeSync()
        let rediscovered = await module.syncStatus()
        XCTAssertFalse(rediscovered.isEnabled)
        XCTAssertEqual(rediscovered.cloudReset?.failure, .failed(.providerRejected))
        let rediscoveredAttempts = await cloud.resetRequestCount()
        XCTAssertEqual(rediscoveredAttempts, oldAttempts, "Account discovery cannot turn an automatic wakeup into explicit retry consent")

        await cloud.allowReset()
        await module.retrySync(waitForSync: false)
        for _ in 0..<200 {
            if await module.syncStatus().cloudReset?.stage == .completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let completed = await module.syncStatus()
        XCTAssertFalse(completed.isEnabled)
        XCTAssertEqual(completed.cloudReset?.stage, .completed)
        let retained = try await module.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
    }

    func testExplicitActivationOfPreviousResetAccountKeepsOffRetryUsable() async throws {
        for waitForSync in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-reactivation-\(UUID())")
            removeClipboardHistoryDirectoryAfterTest(root)
            let cloud = ResetRetryCloud()
            let module = makeModule(root: root, cloud: cloud, keys: ResetRetryKeys())
            let local = try await module.capture(.init(source: .unknown, content: .text("retained after explicit account return")))
            try await module.setSyncEnabled(true)
            let confirmation = try await module.prepareCloudReset()
            await cloud.rejectReset(at: .transition, using: ClipboardSyncCloudKit(recordReader: { _, _, _ in
                throw CKError(.serverRejectedRequest)
            }))
            try await module.clearCloudDataAndStopSync(confirmation)
            let oldAttempts = await cloud.resetRequestCount()

            await cloud.switchAccount(to: "new-owner")
            try await module.setSyncEnabled(true)
            let active = await module.syncStatus()
            XCTAssertTrue(active.isEnabled)
            XCTAssertEqual(active.phase, .upToDate)
            // Drain polling before changing the external account so this return
            // exercises explicit On, not the separately tested automatic discovery.
            await module.suspendSync()
            await cloud.switchAccount(to: "reset-owner")
            try await module.setSyncEnabled(true)
            let returned = await module.syncStatus()
            XCTAssertFalse(returned.isEnabled)
            XCTAssertEqual(returned.cloudReset?.failure, .failed(.providerRejected))
            let returnedAttempts = await cloud.resetRequestCount()
            XCTAssertEqual(returnedAttempts, oldAttempts + 1, "Explicit On must reach the previous pending reset")

            await cloud.allowReset()
            await module.retrySync(waitForSync: waitForSync)
            if !waitForSync {
                for _ in 0..<200 {
                    if await module.syncStatus().cloudReset?.stage == .completed { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let completed = await module.syncStatus()
            XCTAssertFalse(completed.isEnabled)
            XCTAssertEqual(completed.cloudReset?.stage, .completed, "A consumed account activation must not prevent Retry while the reset keeps ordinary sync Off")
            let completedAttempts = await cloud.resetRequestCount()
            XCTAssertGreaterThan(completedAttempts, returnedAttempts, "Retry must execute the pending reset after the provider recovers")
            let retained = try await module.page(.init())
            XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
        }
    }

    func testPendingResetProviderDeadlineSurvivesManualRetryAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reset-deadline-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = ResetRetryCloud()
        let keys = ResetRetryKeys()
        let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
        let first = makeModule(root: root, cloud: cloud, keys: keys, now: { clock.withLock { $0 } })
        let local = try await first.capture(.init(source: .unknown, content: .text("retained through backoff")))
        try await first.setSyncEnabled(true)
        let confirmation = try await first.prepareCloudReset()
        await cloud.rejectReset(at: .clear, using: ClipboardSyncCloudKit(recordReader: { _, _, _ in
            throw CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 120.0])
        }))
        try await first.clearCloudDataAndStopSync(confirmation)
        let failed = await first.syncStatus()
        XCTAssertFalse(failed.isEnabled)
        XCTAssertEqual(failed.cloudReset?.failure, .failed(.network))
        let requests = await cloud.requestCount()
        await cloud.allowReset()
        await first.retrySync()
        await first.resumeSync()
        try await Task.sleep(for: .milliseconds(160))
        let early = await cloud.requestCount()
        XCTAssertEqual(early, requests, "Explicit Retry and polling must preserve the reset's provider deadline")
        try await first.closeStoreForTesting()

        let reopened = makeModule(root: root, cloud: cloud, keys: keys, now: { clock.withLock { $0 } })
        await reopened.resumeSync()
        clock.withLock { $0 = Date(timeIntervalSince1970: 1_119) }
        await reopened.retrySync(waitForSync: false)
        try await Task.sleep(for: .milliseconds(160))
        let reopenedRequests = await cloud.requestCount()
        XCTAssertEqual(reopenedRequests, requests, "Restart and the intent-only Retry must not shorten or erase the deadline")
        let pending = await reopened.syncStatus()
        XCTAssertTrue(pending.cloudReset?.isPending == true)
        XCTAssertFalse(pending.isEnabled)

        clock.withLock { $0 = Date(timeIntervalSince1970: 1_120) }
        await reopened.retrySync()
        let completed = await reopened.syncStatus()
        XCTAssertEqual(completed.cloudReset?.stage, .completed)
        XCTAssertFalse(completed.isEnabled)
        let retained = try await reopened.page(.init())
        XCTAssertEqual(retained.entries.map(\.id), [local.entryID])
    }

    private func makeModule(root: URL, cloud: ResetRetryCloud, keys: ResetRetryKeys,
        now: @escaping @Sendable () -> Date = { Date() }) -> ClipboardHistoryModule {
        trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: ResetRetryLocalKey(), now: now,
            syncServices: .init(transport: cloud, keys: keys, pollingInterval: .milliseconds(40))))
    }
}

private enum ResetRetryFaultBoundary: Sendable { case transition, clear }

private struct ResetRetryLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x76, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor ResetRetryKeys: ClipboardSyncKeyStoring {
    private var values: [String: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { values[account.identifier + keyID.uuidString] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        let id = account.identifier + keyID.uuidString
        if let existing = values[id], existing != key { throw ClipboardSyncServiceError.corruptData }
        values[id] = key
        return key
    }
}

private actor ResetRetryCloud: ClipboardSyncTransport {
    private var owner = "reset-owner"
    private var controls: [String: ClipboardSyncControl] = [:]
    private var requests = 0
    private var resetRequests = 0
    private var faultBoundary: ResetRetryFaultBoundary?
    private var nativeFailure: ClipboardSyncCloudKit?

    func requestCount() -> Int { requests }
    func resetRequestCount() -> Int { resetRequests }
    func switchAccount(to owner: String) { self.owner = owner }
    func rejectReset(at boundary: ResetRetryFaultBoundary, using native: ClipboardSyncCloudKit) {
        faultBoundary = boundary
        nativeFailure = native
    }
    func allowReset() { nativeFailure = nil }
    func account() -> ClipboardSyncAccount {
        requests += 1
        return .init(container: ClipboardSyncNativeConfiguration.container,
            environment: ClipboardSyncNativeConfiguration.environment, owner: owner)
    }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? {
        requests += 1
        return controls[account.identifier]
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        requests += 1
        if let existing = controls[account.identifier] { return existing }
        controls[account.identifier] = candidate
        return candidate
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        requests += 1
        return .init(records: [], cursor: nil, hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        requests += 1
        throw ClipboardSyncServiceError.recordUnavailable
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) -> ClipboardSyncControl {
        requests += 1
        return control
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) throws -> ClipboardSyncControl {
        requests += 1
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) throws -> Data {
        requests += 1
        throw ClipboardSyncServiceError.recordUnavailable
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
        for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        requests += 1
        resetRequests += 1
        guard controls[account.identifier] == control else { throw ClipboardSyncServiceError.conflict }
        if faultBoundary == .transition, let nativeFailure { _ = try await nativeFailure.control(for: account) }
        let updated = ClipboardSyncControl(accountID: account.identifier, keyID: control.keyID,
            keyCheck: control.keyCheck, epoch: epoch, phase: phase, serverToken: nil)
        controls[account.identifier] = updated
        return updated
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        requests += 1
        resetRequests += 1
        guard controls[account.identifier] == control, control.phase == "resetting" else { throw ClipboardSyncServiceError.conflict }
        if faultBoundary == .clear, let nativeFailure { _ = try await nativeFailure.control(for: account) }
        return .init(control: control, cursor: nil, deletedRecordCount: 0, hasMore: false)
    }
    func cancel() {}
}
