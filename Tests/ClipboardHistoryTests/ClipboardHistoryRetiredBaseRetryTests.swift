import Foundation
import GRDB
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testRetiredBaseMissingBackoffSurvivesRestartAndExplicitConsent() async throws {
        let fixture = try await makeRetiredBaseRetryFixture()
        let clock = RetiredBaseRetryClock()
        let fresh = makeRetiredBaseRetryModule(fixture, clock: clock)
        try await fresh.setSyncEnabled(true)
        let initialStatus = await fresh.syncStatus()
        XCTAssertEqual(initialStatus.phase, .upToDate)
        let plan = try await fresh.fileConflictPlan(entryID: fixture.entryID, objectID: fixture.base.objectID)
        XCTAssertTrue(plan.ancestryComplete)
        XCTAssertTrue(plan.candidates.allSatisfy { $0.availability == .available })
        let initialAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(initialAttempts, 1)

        await fresh.resumeSync()
        try await fresh.closeStoreForTesting()
        let reopened = makeRetiredBaseRetryModule(fixture, clock: clock)
        await reopened.resumeSync()
        clock.set(2_029)
        await reopened.resumeSync()
        let deferredStatus = await reopened.syncStatus()
        let deferredAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(deferredStatus.phase, .upToDate)
        XCTAssertEqual(deferredAttempts, initialAttempts, "Automatic passes and restart must retain the original deadline")

        clock.set(2_030)
        await reopened.resumeSync()
        let dueStatus = await reopened.syncStatus()
        let dueAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(dueStatus.phase, .upToDate)
        XCTAssertEqual(dueAttempts, initialAttempts + 1, "Reading a retry must not extend its deadline")

        try await reopened.requestSyncFileDownload(entryID: fixture.entryID, objectID: fixture.base.objectID,
            versionID: fixture.base.baseVersionID)
        let requestedStatus = await reopened.syncStatus()
        let requestedAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(requestedStatus.phase, .failed(.network), "An exact-version request makes the historical bytes required")
        XCTAssertEqual(requestedAttempts, dueAttempts + 1)
        try await reopened.closeStoreForTesting()
        let requestedReopen = makeRetiredBaseRetryModule(fixture, clock: clock)
        await requestedReopen.resumeSync()
        let requestedReopenStatus = await requestedReopen.syncStatus()
        let requestedReopenAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(requestedReopenStatus.phase, .failed(.network))
        XCTAssertEqual(requestedReopenAttempts, requestedAttempts)
    }

    @MainActor
    func testMissingConflictHeadStillReportsFailureAndHonorsExplicitRetry() async throws {
        let fixture = try await makeRetiredBaseRetryFixture()
        await fixture.transport.setFault(.missing, version: fixture.heads[0])
        let clock = RetiredBaseRetryClock()
        let fresh = makeRetiredBaseRetryModule(fixture, clock: clock)
        try await fresh.setSyncEnabled(true)
        let status = await fresh.syncStatus()
        XCTAssertEqual(status.phase, .failed(.network))
        let plan = try await fresh.fileConflictPlan(entryID: fixture.entryID, objectID: fixture.base.objectID)
        XCTAssertTrue(plan.ancestryComplete)
        XCTAssertEqual(plan.candidates.filter { $0.availability == .available }.count, 1)
        let attempts = await fixture.transport.attempts(fixture.heads[0])
        XCTAssertEqual(attempts, 1)
        try await fresh.closeStoreForTesting()
        let reopened = makeRetiredBaseRetryModule(fixture, clock: clock)
        await reopened.resumeSync()
        let reopenedStatus = await reopened.syncStatus()
        let reopenedAttempts = await fixture.transport.attempts(fixture.heads[0])
        XCTAssertEqual(reopenedStatus.phase, .failed(.network))
        XCTAssertEqual(reopenedAttempts, attempts)
        let currentPlan = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: fixture.base.objectID)
        try await reopened.requestFileConflictDownload(currentPlan, versionID: fixture.heads[0])
        let requestedStatus = await reopened.syncStatus()
        let requestedAttempts = await fixture.transport.attempts(fixture.heads[0])
        XCTAssertEqual(requestedStatus.phase, .failed(.network))
        XCTAssertEqual(requestedAttempts, attempts + 1)
    }

    @MainActor
    func testRetiredBaseCorruptionAndMissingAuthorityRemainFailures() async throws {
        for (fault, expected) in [(RetiredBaseReadFault.corruptBody, ClipboardHistorySyncPhase.failed(.corruptData)),
                                  (.missingAuthority, .failed(.recoveryRequired))] {
            let fixture = try await makeRetiredBaseRetryFixture()
            await fixture.transport.setFault(fault, version: fixture.base.baseVersionID)
            let clock = RetiredBaseRetryClock()
            let fresh = makeRetiredBaseRetryModule(fixture, clock: clock)
            try await fresh.setSyncEnabled(true)
            let status = await fresh.syncStatus()
            XCTAssertEqual(status.phase, expected)
            try await fresh.closeStoreForTesting()
            let reopened = makeRetiredBaseRetryModule(fixture, clock: clock)
            await reopened.resumeSync()
            let reopenedStatus = await reopened.syncStatus()
            XCTAssertEqual(reopenedStatus.phase, expected, "A historical selection does not hide non-missing errors")
            if case .corruptBody = fault {
                let attempts = await fixture.transport.attempts(fixture.base.baseVersionID)
                XCTAssertEqual(attempts, 1, "The real authentication failure retains its object backoff")
            }
        }
    }

    @MainActor
    func testLegacyRetiredBaseRetryRemainsConservativeUntilARealRead() async throws {
        let fixture = try await makeRetiredBaseRetryFixture()
        let clock = RetiredBaseRetryClock()
        let fresh = makeRetiredBaseRetryModule(fixture, clock: clock)
        try await fresh.setSyncEnabled(true)
        // Freeze the old on-disk phase representation on an otherwise real,
        // already-produced retry. Do not seed graph, intent, or retry deadlines.
        let legacyPhase = Data(#"{"failed":{"_0":"network"}}"#.utf8)
        let legacy = try await replaceRetiredBaseRetryPhase(legacyPhase, in: fresh, fixture: fixture, clock: clock)
        await legacy.resumeSync()
        let legacyStatus = await legacy.syncStatus()
        XCTAssertEqual(legacyStatus.phase, .failed(.network))
        try await legacy.closeStoreForTesting()
        let reopened = makeRetiredBaseRetryModule(fixture, clock: clock)
        clock.set(2_029)
        await reopened.resumeSync()
        let deferredStatus = await reopened.syncStatus()
        let deferredAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(deferredStatus.phase, .failed(.network))
        XCTAssertEqual(deferredAttempts, 1)
        clock.set(2_030)
        await reopened.resumeSync()
        let dueStatus = await reopened.syncStatus()
        let dueAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(dueStatus.phase, .upToDate)
        XCTAssertEqual(dueAttempts, 2)

        let explicit = try await replaceRetiredBaseRetryPhase(legacyPhase, in: reopened, fixture: fixture, clock: clock)
        await explicit.resumeSync()
        await explicit.retrySync()
        let explicitStatus = await explicit.syncStatus()
        let explicitAttempts = await fixture.transport.attempts(fixture.base.baseVersionID)
        XCTAssertEqual(explicitStatus.phase, .upToDate)
        XCTAssertEqual(explicitAttempts, 3)
        let malformed = try await replaceRetiredBaseRetryPhase(Data(#"{"phase":{"failed":{"_0":"network"}}}"#.utf8),
            in: explicit, fixture: fixture, clock: clock)
        await malformed.resumeSync()
        let malformedStatus = await malformed.syncStatus()
        XCTAssertEqual(malformedStatus.phase, .failed(.localStorage), "A malformed new retry is not a legacy phase or a missing record")
    }

    @MainActor
    private func replaceRetiredBaseRetryPhase(_ phase: Data, in module: ClipboardHistoryModule,
        fixture: RetiredBaseRetryFixture, clock: RetiredBaseRetryClock) async throws -> ClipboardHistoryModule {
        try await module.closeStoreForTesting()
        let workID = "download/\(fixture.base.baseVersionID.uuidString)"
        let keys = ClipboardHistoryKeyDerivation.deriveV1(from: Data(repeating: 0x53, count: 32))
        let database = try ClipboardHistoryModule.openDatabase(
            at: ClipboardHistoryModule.databaseURL(in: fixture.receiverRoot), databaseKey: keys.databaseKey)
        do {
            try await database.write { database in
                try database.execute(sql: "UPDATE clipboard_sync_file_retries SET phase = ? WHERE work_id = ?", arguments: [phase, workID])
                XCTAssertEqual(database.changesCount, 1, "The compatibility fixture must replace one real persisted retry")
            }
        } catch {
            try database.close()
            throw error
        }
        try database.close()
        return makeRetiredBaseRetryModule(fixture, clock: clock)
    }

    private func makeRetiredBaseRetryModule(_ fixture: RetiredBaseRetryFixture,
        clock: RetiredBaseRetryClock) -> ClipboardHistoryModule {
        trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: fixture.receiverRoot,
            keyStore: RetiredBaseRetryKey(), now: { clock.now() }, syncServices: fixture.services))
    }

    @MainActor
    private func makeRetiredBaseRetryFixture() async throws -> RetiredBaseRetryFixture {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.page(.init())
        let base = try XCTUnwrap(initial.entries.first?.linkedFileLocations.first)
        let tag = try XCTUnwrap(initial.entries.first?.tagIDs.first)
        try await fixture.sender.setSyncEnabled(false)
        let parents = [UUID(), UUID()], heads = [UUID(), UUID()]
        for (id, ancestry, bytes) in [
            (heads[0], [parents[0]], Data("first head".utf8)),
            (heads[1], [parents[1]], Data("second head".utf8)),
            (parents[0], [base.baseVersionID], Data("first parent".utf8)),
            (parents[1], [base.baseVersionID], Data("second parent".utf8))
        ] {
            _ = try await commitConflictRemoteFile(bytes: bytes, versionID: id, parents: ancestry,
                objectID: base.objectID, root: fixture.root, services: fixture.services, cloud: fixture.cloud)
        }
        await fixture.receiver.retrySync()
        try await fixture.receiver.setSyncTagSelected(tag, selected: false)
        try await fixture.receiver.setSyncTagSelected(tag, selected: true)
        let account = await fixture.cloud.account()
        let observed = await fixture.cloud.control(for: account)
        var control = try XCTUnwrap(observed)
        let loaded = try await fixture.services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let uploads = await fixture.cloud.uploadedRecords()
        let checkpoint = try XCTUnwrap(uploads.reversed().first {
            if case .rejoin = try? ClipboardSyncCodec.open($0.record, chunks: $0.chunks,
                account: account, control: control, key: key) { return true }
            return false
        })
        guard case .rejoin(let value) = try ClipboardSyncCodec.open(checkpoint.record, chunks: checkpoint.chunks,
            account: account, control: control, key: key) else { throw ClipboardSyncServiceError.corruptData }
        let ordered = try XCTUnwrap(value.fileVersions).sorted {
            func rank(_ id: UUID) -> Int { id == base.baseVersionID ? 0 : parents.contains(id) ? 2 : 1 }
            return rank($0.descriptor.versionID) < rank($1.descriptor.versionID)
        }
        let replay = ClipboardSyncRejoin(state: value.state, entry: value.entry, initialRecordID: value.initialRecordID,
            versions: value.versions, selectedVersionID: value.selectedVersionID, metadata: value.metadata,
            memberships: value.memberships, fileVersions: ordered)
        for upload in uploads {
            if case .fileVersion = try? ClipboardSyncCodec.open(upload.record, chunks: upload.chunks,
                account: account, control: control, key: key) {
                control = try await fixture.services.transport.purge(upload.record, for: account, control: control)
            }
        }
        control = try await fixture.services.transport.purge(checkpoint.record, for: account, control: control)
        _ = try await fixture.cloud.commit(ClipboardSyncCodec.seal(.rejoin(replay), account: account,
            control: control, key: key), for: account, control: control)
        let transport = RetiredBaseReadTransport(cloud: fixture.cloud, uploads: uploads)
        return .init(base: base, heads: heads, entryID: fixture.entryID,
            receiverRoot: fixture.root.appendingPathComponent("Fresh retry receiver"), transport: transport,
            services: .init(transport: transport, keys: fixture.services.keys, pollingInterval: nil))
    }
}

private struct RetiredBaseRetryFixture {
    let base: ClipboardHistoryLinkedFileLocation
    let heads: [UUID]
    let entryID: ClipboardHistoryEntryID
    let receiverRoot: URL
    let transport: RetiredBaseReadTransport
    let services: ClipboardSyncServices
}

private struct RetiredBaseRetryKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x53, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private final class RetiredBaseRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval = 2_000
    func now() -> Date { lock.withLock { Date(timeIntervalSince1970: seconds) } }
    func set(_ value: TimeInterval) { lock.withLock { seconds = value } }
}

private enum RetiredBaseReadFault: Sendable { case missing, corruptBody, missingAuthority }

/// Controls only provider reads. The real module authenticates the graph and
/// ciphertext, persists retries, handles consent, and publishes local files.
private actor RetiredBaseReadTransport: ClipboardSyncTransport {
    let cloud: any ClipboardSyncTransport
    let uploads: [ClipboardSyncUpload]
    private var faults: [UUID: RetiredBaseReadFault] = [:]
    private var reads: [UUID: Int] = [:]
    init(cloud: LinkedFileCloud, uploads: [ClipboardSyncUpload]) { self.cloud = cloud; self.uploads = uploads }
    func setFault(_ fault: RetiredBaseReadFault, version: UUID) { faults[version] = fault }
    func attempts(_ version: UUID) -> Int { reads[version, default: 0] }
    func account() async throws -> ClipboardSyncAccount { try await cloud.account() }
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl? { try await cloud.control(for: account) }
    func createControl(_ control: ClipboardSyncControl, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        try await cloud.createControl(control, for: account)
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncChanges {
        try await cloud.changes(for: account, control: control, cursor: cursor)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) async throws -> [Data] {
        if let override = try overrideRead(record) { return override }
        return try await cloud.download(record, for: account)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        if let override = try overrideRead(record) { return override[index] }
        return try await cloud.downloadFileSegment(record, index: index, for: account)
    }
    private func overrideRead(_ record: ClipboardSyncRemoteRecord) throws -> [Data]? {
        if record.kind == .fileBody {
            reads[record.operationID, default: 0] += 1
            switch faults[record.operationID] {
            case .missing: throw ClipboardSyncServiceError.recordUnavailable
            case .missingAuthority: throw ClipboardSyncServiceError.missingRemoteState
            case .corruptBody:
                var chunks = try XCTUnwrap(uploads.first { $0.record == record }).chunks
                chunks[0][0] ^= 1
                return chunks
            case nil: break
            }
        }
        return nil
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await cloud.commit(upload, for: account, control: control)
    }
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl,
        progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        try await cloud.commitFile(upload, for: account, control: control, progress: progress)
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount, control: ClipboardSyncControl) async throws -> ClipboardSyncControl {
        try await cloud.purge(record, for: account, control: control)
    }
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID, for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        try await cloud.transition(control, to: phase, epoch: epoch, for: account)
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        try await cloud.clearPage(for: account, control: control, cursor: cursor)
    }
    func cancel() async { await cloud.cancel() }
}
