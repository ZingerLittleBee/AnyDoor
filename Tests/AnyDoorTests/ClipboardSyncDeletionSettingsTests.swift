import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncDeletionSettingsTests: XCTestCase {
    func testClearDisclosureAndPreservedEditNoticeUseProductionSettingsActions() async throws {
        let cloud = DeletionSettingsCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: DeletionSettingsKeys(), pollingInterval: nil)
        let first = makeModule(services: services)
        let second = makeModule(services: services)
        let shared = try await first.capture(.init(source: .unknown, content: .text("shared settings note")))
        let tag = try await first.createTagDefinition(named: "Settings", assigningTo: shared.entryID)
        try await first.setSyncTagSelected(tag.definition.id, selected: true)
        try await first.setSyncEnabled(true)
        try await second.setSyncEnabled(true)
        await second.suspendSync()
        _ = try await second.apply(.editText(shared.entryID, "saved offline in settings"))

        let defaults = makeTemporaryDefaults()
        let lifecycle = ClipboardHistoryLifecycle(module: first, defaults: defaults, migrationRequest: nil)
        let settings = ClipboardHistorySettingsModel(module: first, lifecycle: lifecycle,
            presentation: SettingsPresentation(), defaults: defaults)
        await settings.beginClearHistory()
        XCTAssertEqual(settings.clearConfirmation?.preview.sharedAffectedCount, 0)
        await settings.setClearIncludesProtected(true)
        XCTAssertEqual(settings.clearConfirmation?.preview.sharedAffectedCount, 1)
        await settings.confirmClearHistory()
        XCTAssertNil(settings.clearConfirmation)
        XCTAssertFalse(settings.operationFailed)
        await first.retrySync()
        await second.resumeSync()

        let receiverSettings = ClipboardSyncSettingsModel(module: second)
        await receiverSettings.refresh()
        XCTAssertEqual(receiverSettings.preservedEdits.map(\.previewText), ["saved offline in settings"])
        let copy = try XCTUnwrap(receiverSettings.preservedEdits.first)
        XCTAssertNotEqual(copy.id, shared.entryID)
        let local = try await second.page(.init())
        XCTAssertEqual(local.entries.map(\.id), [copy.id])
        await receiverSettings.dismissPreservedEdits()
        XCTAssertTrue(receiverSettings.preservedEdits.isEmpty)
        let reopenedSettings = ClipboardSyncSettingsModel(module: second)
        await reopenedSettings.refresh()
        XCTAssertTrue(reopenedSettings.preservedEdits.isEmpty)
        try await second.setSyncTagSelected(tag.definition.id, selected: true)
        await second.retrySync()
        await first.retrySync()
        let sender = try await first.page(.init())
        XCTAssertTrue(sender.entries.isEmpty)
    }

    private func makeModule(services: ClipboardSyncServices) -> ClipboardHistoryModule {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-settings-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        return trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: DeletionSettingsLocalKey(), syncServices: services))
    }
}

private struct DeletionSettingsLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x4C, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor DeletionSettingsKeys: ClipboardSyncKeyStoring {
    private var values: [UUID: Data] = [:]
    func load(account: ClipboardSyncAccount, keyID: UUID) -> Data? { values[keyID] }
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) -> Data {
        if let existing = values[keyID] { return existing }
        values[keyID] = key
        return key
    }
}

private actor DeletionSettingsCloud: ClipboardSyncTransport {
    private let identity = ClipboardSyncAccount(container: "test", environment: "test", owner: "settings")
    private var descriptor: ClipboardSyncControl?
    private var uploads: [ClipboardSyncUpload] = []
    private var removed = Set<String>()
    private var revision = 0

    func account() -> ClipboardSyncAccount { identity }
    func control(for account: ClipboardSyncAccount) -> ClipboardSyncControl? { descriptor }
    func createControl(_ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount) -> ClipboardSyncControl {
        if let descriptor { return descriptor }
        let created = advance(candidate)
        descriptor = created
        return created
    }
    func changes(for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?) -> ClipboardSyncChanges {
        let offset = cursor.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        return .init(records: uploads.dropFirst(offset).map(\.record).filter { !removed.contains($0.recordID) },
            cursor: Data(String(uploads.count).utf8), hasMore: false)
    }
    func download(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount) throws -> [Data] {
        guard let found = uploads.first(where: { $0.record == record }), !removed.contains(record.recordID) else {
            throw ClipboardSyncServiceError.recordUnavailable
        }
        return found.chunks
    }
    func commit(_ upload: ClipboardSyncUpload, for account: ClipboardSyncAccount,
                control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        guard let current = descriptor, current == control else { throw ClipboardSyncServiceError.conflict }
        if !uploads.contains(where: { $0.record.recordID == upload.record.recordID }) { uploads.append(upload) }
        let committed = advance(current)
        descriptor = committed
        return committed
    }
    func purge(_ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount,
               control: ClipboardSyncControl) throws -> ClipboardSyncControl {
        guard let current = descriptor, current == control else { throw ClipboardSyncServiceError.conflict }
        removed.insert(record.recordID)
        let purged = advance(current)
        descriptor = purged
        return purged
    }
    func cancel() {}
    private func advance(_ value: ClipboardSyncControl) -> ClipboardSyncControl {
        revision += 1
        return .init(accountID: value.accountID, keyID: value.keyID, keyCheck: value.keyCheck,
            epoch: value.epoch, phase: value.phase, serverToken: Data(String(revision).utf8))
    }
}
