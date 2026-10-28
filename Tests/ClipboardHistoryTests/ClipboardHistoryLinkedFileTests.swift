import AppKit
import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistoryLinkedFileTests: XCTestCase {
    @MainActor
    func testOriginalAndManagedWorkingLocationsKeepTheirIdentityAfterRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let originals = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let working = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)

        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(originals.first?.kind, .original)
        XCTAssertEqual(originals.first?.url.standardizedFileURL, fixture.original.standardizedFileURL)
        XCTAssertEqual(working.count, 1)
        XCTAssertEqual(working.first?.kind, .workingCopy)
        XCTAssertEqual(working.first?.objectID, originals.first?.objectID)
        let location = try XCTUnwrap(working.first)
        XCTAssertNotEqual(location.url, fixture.original)
        XCTAssertEqual(try Data(contentsOf: location.url), Data("initial linked bytes".utf8))
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored, working)
    }

    @MainActor
    private func makeLinkedFixture() async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule,
        entryID: ClipboardHistoryEntryID, original: URL, root: URL, receiverRoot: URL,
        services: ClipboardSyncServices, cloud: LinkedFileCloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-files-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("Linked notes.txt")
        try Data("initial linked bytes".utf8).write(to: original)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x51)
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0x52)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.linked-files.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Linked", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        return (sender, receiver, capture.entryID, original, root, receiverRoot, services, cloud)
    }

    private func makeLinkedModule(root: URL, services: ClipboardSyncServices, key: UInt8) -> ClipboardHistoryModule {
        trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: LinkedFileLocalKey(byte: key), syncServices: services))
    }
}

private struct LinkedFileLocalKey: ClipboardHistoryMasterKeyStoring {
    let byte: UInt8
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: byte, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

private actor LinkedFileKeys: ClipboardSyncKeyStoring {
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

private actor LinkedFileCloud: ClipboardSyncTransport {
    private let identity = ClipboardSyncAccount(container: "test", environment: "test", owner: "linked-file-user")
    private var currentControl: ClipboardSyncControl?
    private var uploads: [ClipboardSyncUpload] = []

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
    func uploadCount() -> Int { uploads.count }
    private func advanced(_ control: ClipboardSyncControl) -> ClipboardSyncControl {
        .init(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: control.epoch, phase: control.phase, serverToken: Data(UUID().uuidString.utf8))
    }
}
