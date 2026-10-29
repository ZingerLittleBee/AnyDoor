import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testDeletionPreservesOnlyTheLatestPendingDraftAboveLongAuthenticatedAncestry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("deletion-long-ancestry-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0xB3)
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
        _ = try await cloud.commit(upload, for: account, control: control)
        await sender.resumeSync()
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0xB4)
        try await receiver.setSyncEnabled(true)
        let plan = try await receiver.textEditPlan(for: capture.entryID)
        XCTAssertEqual(plan.versions.map(\.id), [parent])
        await receiver.suspendSync()
        _ = try await receiver.apply(.editText(capture.entryID, "superseded offline draft"))
        _ = try await receiver.apply(.editText(capture.entryID, "latest offline draft"))
        _ = try await sender.apply(.delete(capture.entryID))
        await sender.retrySync()
        await receiver.resumeSync()
        let saved = try await receiver.preservedSyncEdits()
        XCTAssertEqual(saved.map(\.previewText), ["latest offline draft"])
        let preserved = try XCTUnwrap(saved.first)
        XCTAssertNotEqual(preserved.id, capture.entryID)
        let page = try await receiver.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [preserved.id])
        try await receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: receiverRoot, services: services, key: 0xB4)
        await reopened.resumeSync()
        let afterRestart = try await reopened.preservedSyncEdits()
        XCTAssertEqual(afterRestart, saved)
        await reopened.retrySync()
        await sender.retrySync()
        let peer = try await sender.page(.init())
        XCTAssertTrue(peer.entries.isEmpty, "Preserved local work must not resurrect a deleted shared entry")
    }
}
