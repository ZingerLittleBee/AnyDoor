import AppKit
import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistoryLinkedFileTests: XCTestCase {
    @MainActor
    func testDisabledLocationDefersObservationAndReconcilesSavedBytesAfterRestart() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.cloud.failCommits(true)
        try await fixture.sender.setSyncEnabled(false)
        let saved = Data("saved while this device was disabled".utf8)
        try saved.write(to: fixture.original)
        try await Task.sleep(for: .milliseconds(700))
        let disabled = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(disabled.first?.state, .current)
        try await fixture.sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Sender"), services: fixture.services, key: 0x51)

        try await reopened.setSyncEnabled(true)

        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(restored.first?.id, disabled.first?.id)
        XCTAssertTrue(restored.first?.state == .localChanges || restored.first?.state == .pendingUpload)
        XCTAssertEqual(try Data(contentsOf: fixture.original), saved)
    }

    @MainActor
    func testSavedFileChangeIsObservedWithoutRecaptureOrManualRefresh() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.cloud.failCommits(true)
        let changed = Data("saved after association".utf8)

        try changed.write(to: fixture.original)

        let deadline = Date().addingTimeInterval(5)
        var observed: ClipboardHistoryLinkedFileLocationState?
        repeat {
            observed = try await fixture.sender.linkedFileLocations(for: fixture.entryID).first?.state
            if observed == .localChanges || observed == .pendingUpload { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        XCTAssertTrue(observed == .localChanges || observed == .pendingUpload,
            "A real filesystem save must be observed without recapture or manual sync")
        XCTAssertEqual(try Data(contentsOf: fixture.original), changed)
    }

    @MainActor
    func testExplicitAssociationPreservesChosenContentsAndIndependentExportsStayUnlinked() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        let destination = fixture.root.appendingPathComponent("Independent saved copy.txt")
        _ = try await fixture.receiver.exportFiles(fixture.entryID, to: [destination])
        let afterExport = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(afterExport, initial)
        let chosenBytes = Data("keep the chosen file contents".utf8)
        try chosenBytes.write(to: destination)
        try await fixture.receiver.setSyncEnabled(false)

        let associated = try await fixture.receiver.associateFileLocation(.init(
            entryID: fixture.entryID, objectID: working.objectID, url: destination))

        XCTAssertEqual(associated.kind, .associated)
        XCTAssertEqual(associated.state, .localChanges)
        XCTAssertEqual(associated.baseVersionID, working.baseVersionID)
        XCTAssertEqual(try Data(contentsOf: destination), chosenBytes)
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(locations.count, 2)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.linkedFileLocations(for: fixture.entryID)
        XCTAssertTrue(restored.contains(associated))
    }

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
    private var commitsFail = false
    func failCommits(_ fail: Bool) { commitsFail = fail }

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
    func uploadCount() -> Int { uploads.count }
    private func advanced(_ control: ClipboardSyncControl) -> ClipboardSyncControl {
        .init(accountID: control.accountID, keyID: control.keyID, keyCheck: control.keyCheck,
            epoch: control.epoch, phase: control.phase, serverToken: Data(UUID().uuidString.utf8))
    }
}
