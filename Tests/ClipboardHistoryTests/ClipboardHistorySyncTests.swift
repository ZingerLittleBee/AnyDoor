import AppKit
import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistorySyncTests: XCTestCase {
    func testAccountChangeDisablesDeviceAndRequiresFreshSelectionForNewAccount() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let module = makeModule(services: .init(transport: cloud, keys: keys, pollingInterval: nil), keyByte: 0x39, time: 1_000)
        let entry = try await module.capture(.init(source: .unknown, content: .text("account A only")))
        let tag = try await module.createTagDefinition(named: "Account A", assigningTo: entry.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        await cloud.switchAccount(to: "second-user")
        await module.retrySync()
        let stopped = await module.syncStatus()
        XCTAssertFalse(stopped.isEnabled)
        XCTAssertEqual(stopped.phase, .failed(.accountChanged))
        try await module.setSyncEnabled(true)
        let afterManualActivation = await module.syncStatus()
        XCTAssertTrue(afterManualActivation.isEnabled)
        let choices = try await module.syncTags()
        XCTAssertTrue(choices.allSatisfy { !$0.isSelected })
        let cloudRecords = await cloud.currentUploads()
        XCTAssertTrue(cloudRecords.isEmpty)
        let local = try await module.page(.init())
        XCTAssertEqual(local.entries.map(\.id), [entry.entryID])
    }

    @MainActor
    func testSelectedTextArrivesAsHistoryWithOriginalProvenanceAndNoPasteboardWrite() async throws {
        let cloud = SyncTestCloud()
        let keys = SyncTestKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let first = makeModule(services: services, keyByte: 0x31, time: 1_000)
        let second = makeModule(services: services, keyByte: 0x42, time: 2_000)
        let source = ClipboardHistoryCaptureSource(bundleIdentifier: "example.editor", displayName: "Editor")
        let captured = try await first.capture(ClipboardHistoryCaptureRequest(
            source: source, content: .text("private example \t\r\n")
        ))
        let tag = try await first.createTagDefinition(named: "Shared work", assigningTo: captured.entryID)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.sync-tests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString("leave this alone", forType: .string)
        let generation = pasteboard.changeCount

        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        let secondBeforeActivation = await second.syncStatus()
        XCTAssertFalse(secondBeforeActivation.isEnabled)
        try await second.setSyncEnabled(true)
        let page = try await second.page(ClipboardHistoryQuery(tagID: tag.definition.id))
        XCTAssertEqual(page.entries.count, 1)
        let received = try XCTUnwrap(page.entries.first)
        XCTAssertEqual(received.capturedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(received.source, source)
        let materialization = try await second.materialize(.init(entryID: received.id, purpose: .normalPaste))
        XCTAssertEqual(materialization.items, [ClipboardHistoryMaterializedItem(representations: [
            .text(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, value: "private example \t\r\n")
        ])])
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.string(forType: .string), "leave this alone")
        let firstStatus = await first.syncStatus()
        let secondStatus = await second.syncStatus()
        XCTAssertEqual(firstStatus.uploadedEntryCount, 1)
        XCTAssertEqual(secondStatus.receivedEntryCount, 1)
        XCTAssertEqual(secondStatus.phase, .upToDate)
    }

    private func makeModule(
        services: ClipboardSyncServices, keyByte: UInt8, time: TimeInterval,
        root: URL? = nil
    ) -> ClipboardHistoryModule {
        let root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore(byte: keyByte),
            now: { Date(timeIntervalSince1970: time) },
            syncServices: services
        ))
    }

    func testSyncTagsShowExistingEligibleTextWithoutEnablingDevice() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root, keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("shared later")
        ))
        let tag = try await module.createTagDefinition(named: "Work", assigningTo: captured.entryID)
        let choices = try await module.syncTags()
        XCTAssertEqual(choices, [ClipboardHistorySyncTag(
            id: tag.definition.id, displayName: "Work", isSelected: false, eligibleEntryCount: 1
        )])
        let status = await module.syncStatus()
        XCTAssertFalse(status.isEnabled)
    }

    func testNewDeviceStartsDisabledAndKeepsLocalHistoryUsable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-sync-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: SyncTestLocalKeyStore()
        ))
        let captured = try await module.capture(ClipboardHistoryCaptureRequest(
            source: .unknown, content: .text("local only")
        ))
        let status = await module.syncStatus()
        XCTAssertEqual(status.phase, .disabled)
        XCTAssertFalse(status.isEnabled)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id), [captured.entryID])
    }
}

private struct SyncTestLocalKeyStore: ClipboardHistoryMasterKeyStoring {
    var byte: UInt8 = 0x67
    func load() -> ClipboardHistoryMasterKeyResult {
        .key(Data(repeating: byte, count: 32))
    }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor SyncTestCloud: ClipboardSyncTransport {
    private var currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: "test-user")
    private var descriptors: [String: ClipboardSyncControl] = [:]
    private var records: [String: [ClipboardSyncUpload]] = [:]
    private var revision = 0

    func account() -> ClipboardSyncAccount { currentAccount }
    func control(for account: ClipboardSyncAccount) throws -> ClipboardSyncControl? {
        try checkAccount(account)
        return descriptors[account.identifier]
    }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        if let descriptor = descriptors[account.identifier] { return descriptor }
        let result = advanced(candidate)
        descriptors[account.identifier] = result
        return result
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        let uploads = records[account.identifier] ?? []
        return ClipboardSyncChanges(records: uploads.dropFirst(offset).map(\.record),
            cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        try checkAccount(account)
        guard let upload = records[account.identifier]?.first(where: { $0.record == record }) else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        return upload.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount,
                control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        try checkAccount(account)
        guard let descriptor = descriptors[account.identifier], descriptor.epoch == control.epoch else {
            throw ClipboardSyncServiceError.missingRemoteState
        }
        if let existing = records[account.identifier]?.first(where: { $0.record.recordID == upload.record.recordID }) {
            guard existing == upload else { throw ClipboardSyncServiceError.corruptData }
            return descriptor
        }
        guard descriptor.serverToken == control.serverToken else { throw ClipboardSyncServiceError.conflict }
        records[account.identifier, default: []].append(upload)
        let result = advanced(descriptor)
        descriptors[account.identifier] = result
        return result
    }
    func cancel() {}
    func switchAccount(to owner: String) {
        currentAccount = ClipboardSyncAccount(container: "test", environment: "test", owner: owner)
    }
    func currentUploads() -> [ClipboardSyncUpload] { records[currentAccount.identifier] ?? [] }
    private func checkAccount(_ account: ClipboardSyncAccount) throws {
        guard currentAccount == account else { throw ClipboardSyncServiceError.accountChanged }
    }
    private func advanced(_ value: ClipboardSyncControl) -> ClipboardSyncControl {
        revision += 1
        return ClipboardSyncControl(accountID: value.accountID, keyID: value.keyID,
            keyCheck: value.keyCheck, epoch: value.epoch, phase: value.phase,
            serverToken: Data(String(revision).utf8))
    }
}

private actor SyncTestKeys: ClipboardSyncKeyStoring {
    private var values: [String: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? {
        values[account.identifier + keyID.uuidString]
    }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        let id = account.identifier + keyID.uuidString
        if let existing = values[id], existing != key { throw ClipboardSyncServiceError.corruptData }
        values[id] = key
        return key
    }
}
