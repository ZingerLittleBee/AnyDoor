import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardFileConflictPresentationTests: XCTestCase {
    func testConflictSheetLoadsRealCandidatesAndCancelPreservesBothFiles() async throws {
        let fixture = try await makeConflictFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)

        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)

        let plan = try XCTUnwrap(model.fileConflictPlan)
        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(model.fileConflictEntryID, fixture.entryID)
        XCTAssertTrue(plan.candidates.contains { $0.id == .localLocation(fixture.location.id) && $0.availability == .available })
        model.dismissFileConflict()
        XCTAssertNil(model.fileConflictEntryID)
        XCTAssertNil(model.fileConflictPlan)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), Data("local edited contents".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("other Mac edited contents".utf8))
    }

    func testChangingLocalBytesRefreshesStaleChoiceWithoutClaimingSuccess() async throws {
        let fixture = try await makeConflictFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)
        let previous = try XCTUnwrap(model.fileConflictPlan)
        let newer = Data("edited while reviewing choices".utf8)
        try newer.write(to: fixture.location.url)

        await model.resolveFileConflict(choosing: .localLocation(fixture.location.id))

        XCTAssertEqual(model.fileConflictNotice, .changed)
        XCTAssertNotEqual(model.fileConflictPlan?.id, previous.id)
        XCTAssertNotNil(model.fileConflictPlan)
        XCTAssertFalse(model.isPerformingFileConflictAction)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), newer)
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("other Mac edited contents".utf8))
    }

    func testLargeCandidateDownloadsOnlyOnRequestAndRefreshesBeforeUse() async throws {
        let remote = Data(repeating: 0x76, count: 6 * 1_024 * 1_024)
        let fixture = try await makeConflictFixture(remote: remote)
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        let before = await fixture.cloud.downloadCount()
        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)
        let plan = try XCTUnwrap(model.fileConflictPlan)
        let candidate = try XCTUnwrap(plan.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let versionID) = candidate.id else { return XCTFail("Expected a shared version") }
        XCTAssertEqual(candidate.availability, .requiresDownload)
        let inspected = await fixture.cloud.downloadCount()
        XCTAssertEqual(inspected, before)
        await model.resolveFileConflict(choosing: candidate.id)
        XCTAssertNil(model.fileConflictNotice)
        let beforeRequest = await fixture.cloud.downloadCount()
        XCTAssertEqual(beforeRequest, before)

        await model.downloadFileConflictVersion(versionID)

        let refreshed = try XCTUnwrap(model.fileConflictPlan)
        let available = try XCTUnwrap(refreshed.candidates.first { $0.id == candidate.id })
        XCTAssertEqual(refreshed.id, plan.id, "Download availability changes without changing the persisted account/version/file basis")
        XCTAssertEqual(available.availability, .available)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(available.localURL)), remote)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), Data("local edited contents".utf8))
        XCTAssertNil(model.fileConflictNotice)
        let downloaded = await fixture.cloud.downloadCount()
        XCTAssertGreaterThan(downloaded, before)
        await model.resolveFileConflict(choosing: candidate.id)
        XCTAssertEqual(model.fileConflictNotice, .submitted)
        XCTAssertNil(model.fileConflictPlan)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), remote)
    }

    func testOfflineChoiceIsSavedWithoutClaimingRemoteConvergence() async throws {
        let fixture = try await makeConflictFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)
        await fixture.cloud.failCommits(true)

        await model.resolveFileConflict(choosing: .localLocation(fixture.location.id))

        XCTAssertEqual(model.fileConflictNotice, .submitted)
        XCTAssertNil(model.fileConflictPlan)
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("other Mac edited contents".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), Data("local edited contents".utf8))
        await fixture.cloud.failCommits(false)
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        XCTAssertEqual(try Data(contentsOf: fixture.original), Data("local edited contents".utf8))
    }

    func testFailedDownloadStaysUnselectableAndCanBeRetried() async throws {
        let fixture = try await makeConflictFixture(remote: Data(repeating: 0x76, count: 6 * 1_024 * 1_024))
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)
        let candidate = try XCTUnwrap(model.fileConflictPlan?.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let versionID) = candidate.id else { return XCTFail("Expected a shared version") }
        await fixture.cloud.failDownloads(true)

        await model.downloadFileConflictVersion(versionID)

        XCTAssertEqual(model.fileConflictNotice, .downloadPending)
        XCTAssertEqual(model.fileConflictPlan?.candidates.first { $0.id == candidate.id }?.availability, .requiresDownload)
        await model.resolveFileConflict(choosing: candidate.id)
        XCTAssertEqual(model.fileConflictNotice, .downloadPending)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), Data("local edited contents".utf8))
        await fixture.cloud.failDownloads(false)
        await model.downloadFileConflictVersion(versionID)
        XCTAssertNil(model.fileConflictNotice)
        XCTAssertEqual(model.fileConflictPlan?.candidates.first { $0.id == candidate.id }?.availability, .available)
    }

    func testClosingDuringDownloadDoesNotReopenTheSheet() async throws {
        let fixture = try await makeConflictFixture(remote: Data(repeating: 0x76, count: 6 * 1_024 * 1_024))
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginFileConflict(entryID: fixture.entryID, objectID: fixture.location.objectID)
        let candidate = try XCTUnwrap(model.fileConflictPlan?.candidates.first { if case .version = $0.id { true } else { false } })
        guard case .version(let versionID) = candidate.id else { return XCTFail("Expected a shared version") }
        await fixture.cloud.holdNextDownload()
        let download = Task { await model.downloadFileConflictVersion(versionID) }
        for _ in 0..<1_000 {
            if await fixture.cloud.downloadIsHeld() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let held = await fixture.cloud.downloadIsHeld()
        XCTAssertTrue(held)
        model.dismissFileConflict()
        await fixture.cloud.releaseDownload()
        await download.value

        XCTAssertNil(model.fileConflictEntryID)
        XCTAssertNil(model.fileConflictPlan)
        XCTAssertNil(model.fileConflictNotice)
        XCTAssertFalse(model.isPerformingFileConflictAction)
        XCTAssertEqual(try Data(contentsOf: fixture.location.url), Data("local edited contents".utf8))
    }

    private func makeConflictFixture(remote: Data = Data("other Mac edited contents".utf8)) async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule,
        entryID: ClipboardHistoryEntryID, location: ClipboardHistoryLinkedFileLocation,
        original: URL, cloud: FileConflictUICloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conflict-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Notes.txt")
        try Data("original contents".utf8).write(to: original)
        let cloud = FileConflictUICloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x41), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x42), syncServices: services))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.conflict-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let locations = try await receiver.linkedFileLocations(for: capture.entryID)
        let location = try XCTUnwrap(locations.first)
        try await sender.setSyncEnabled(false)
        try await receiver.setSyncEnabled(false)
        try remote.write(to: original)
        try Data("local edited contents".utf8).write(to: location.url)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        return (sender, receiver, capture.entryID, location, original, cloud)
    }
}

struct FileConflictUILocalKey: ClipboardHistoryMasterKeyStoring {
    let byte: UInt8
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: byte, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

actor FileConflictUIKeys: ClipboardSyncKeyStoring {
    private var keys: [UUID: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { keys[keyID] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        if let current = keys[keyID] {
            guard current == key else { throw ClipboardSyncServiceError.corruptData }
            return current
        }
        keys[keyID] = key
        return key
    }
}

actor FileConflictUICloud: ClipboardSyncTransport {
    private let identity = ClipboardSyncAccount(container: "test", environment: "test", owner: "linked-file-user")
    private var currentControl: ClipboardSyncControl?
    private var uploads: [ClipboardSyncUpload] = []
    private var commitsFail = false
    private var shouldHoldDownload = false
    private var heldDownload: CheckedContinuation<Void, Never>?
    private var downloads = 0
    private var downloadsFail = false
    func failDownloads(_ fail: Bool) { downloadsFail = fail }
    func downloadCount() -> Int { downloads }
    func uploadCount() -> Int { uploads.count }
    func failCommits(_ fail: Bool) { commitsFail = fail }
    func holdNextDownload() { shouldHoldDownload = true }
    func downloadIsHeld() -> Bool { heldDownload != nil }
    func releaseDownload() { heldDownload?.resume(); heldDownload = nil }

    func account() -> ClipboardSyncAccount { identity }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? { currentControl }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        if let currentControl { return currentControl }
        let created = advanced(candidate)
        currentControl = created
        return created
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return .init(records: uploads.dropFirst(offset).map(\.record), cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        guard let content = uploads.first(where: { $0.record == record }) else { throw ClipboardSyncServiceError.missingRemoteState }
        return content.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount, control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        if commitsFail { throw ClipboardSyncServiceError.network(retryAfter: nil) }
        guard let currentControl, account == identity, currentControl.epoch == control.epoch else {
            throw ClipboardSyncServiceError.accountChanged
        }
        if let current = uploads.first(where: { $0.record.recordID == upload.record.recordID }) {
            guard current == upload else { throw ClipboardSyncServiceError.corruptData }
            return currentControl
        }
        guard currentControl.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        uploads.append(upload)
        let updated = advanced(currentControl)
        self.currentControl = updated
        return updated
    }
    func cancel() {}
    func commitFile(_ upload: ClipboardSyncFileUpload, for account: ClipboardSyncAccount,
        control: ClipboardSyncControl, progress: @Sendable (Int64) async throws -> Void) async throws -> ClipboardSyncControl {
        var chunks: [Data] = []
        var bytes: Int64 = 0
        for index in 0..<upload.record.chunkCount {
            let chunk = try ClipboardSyncFileTransfer.readSegment(in: upload.directory, index: index)
            chunks.append(chunk)
            bytes += Int64(chunk.count)
            try await progress(bytes)
        }
        return try commit(.init(record: upload.record, chunks: chunks), for: account, control: control)
    }
    func downloadFileSegment(_ record: ClipboardSyncRemoteRecord, index: Int, for account: ClipboardSyncAccount) async throws -> Data {
        downloads += 1
        if downloadsFail { throw ClipboardSyncServiceError.network(retryAfter: nil) }
        if shouldHoldDownload {
            shouldHoldDownload = false
            await withCheckedContinuation { heldDownload = $0 }
        }
        let chunks = try download(record, for: account)
        guard chunks.indices.contains(index) else { throw ClipboardSyncServiceError.corruptData }
        return chunks[index]
    }
    private func advanced(_ control: ClipboardSyncControl) -> ClipboardSyncControl {
        .init(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: control.epoch, phase: control.phase, serverToken: Data(UUID().uuidString.utf8))
    }
}
