import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    func testLongAuthenticatedTextAncestryRemainsCompleteAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("long-text-ancestry-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x61)
        let capture = try await sender.capture(.init(source: .unknown, content: .text("ancestry root")))
        let tag = try await sender.createTagDefinition(named: "Ancestry", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await sender.setSyncTagSelected(tag.definition.id, selected: false)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        await sender.suspendSync()
        let account = await cloud.account()
        let current = await cloud.control(for: account)
        let control = try XCTUnwrap(current)
        let loaded = try await services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        var checkpoint: ClipboardSyncRejoin?
        for upload in await cloud.uploadedRecords() {
            if case .rejoin(let value) = try ClipboardSyncCodec.open(upload.record, chunks: upload.chunks,
                account: account, control: control, key: key) { checkpoint = value }
        }
        let original = try XCTUnwrap(checkpoint)
        var versions = original.versions
        var parent = try XCTUnwrap(original.selectedVersionID)
        for index in 1...4_096 {
            let version = ClipboardSyncTextEditContent(id: original.entry.id, versionID: UUID(), parents: [parent],
                text: "authenticated edit \(index)", editedAt: Date(timeIntervalSince1970: 2_000 + Double(index)))
            versions.append(version)
            parent = version.versionID
        }
        let operationID = UUID()
        let updated = ClipboardSyncRejoin(state: .init(sharedID: original.state.sharedID, withdrawn: false,
            revision: .init(counter: original.state.revision.counter + 1, operationID: operationID.uuidString.lowercased())),
            entry: original.entry, initialRecordID: original.initialRecordID, versions: versions,
            selectedVersionID: original.selectedVersionID, metadata: original.metadata,
            memberships: original.memberships, fileVersions: original.fileVersions)
        let upload = try ClipboardSyncCodec.seal(.rejoin(updated), account: account, control: control, key: key, operationID: operationID)
        print("LONG_AUTHENTICATED_ANCESTRY nodes=\(versions.count) encryptedBytes=\(upload.record.encryptedByteCount)")
        _ = try await cloud.commit(upload, for: account, control: control)
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0x62)
        try await receiver.setSyncEnabled(true)
        let plan = try await receiver.textEditPlan(for: capture.entryID)
        XCTAssertFalse(plan.hasConflict)
        XCTAssertEqual(plan.versions.map(\.id), [parent])
        XCTAssertEqual(plan.text, "authenticated edit 4096")
        try await receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: receiverRoot, services: services, key: 0x62)
        await reopened.resumeSync()
        let retained = try await reopened.textEditPlan(for: capture.entryID)
        XCTAssertEqual(retained.versions.map(\.id), [parent])
        let materialized = try await reopened.materialize(.init(entryID: capture.entryID, purpose: .normalPaste))
        XCTAssertTrue(materialized.items.flatMap(\.representations).contains { representation in
            guard case .text(_, let value) = representation else { return false }
            return value == "authenticated edit 4096"
        })
    }
}
