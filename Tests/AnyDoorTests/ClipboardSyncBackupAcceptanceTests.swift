import ClipboardHistoryTestSupport
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardSyncBackupAcceptanceTests: XCTestCase {
    func testRestoredSameNameTagsRequireExplicitMergeAndNeverReenterConfigSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-backup-acceptance-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = makeTemporaryDefaults()
        let cloud = FileConflictUICloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x71), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x72), syncServices: services))
        let shared = try await sender.capture(.init(source: .unknown, content: .text("Already shared before backup restore")))
        let sharedTag = try await sender.createTagDefinition(named: "Work", assigningTo: shared.entryID).definition
        let local = try await receiver.capture(.init(source: .unknown, content: .text("Share only after the displayed merge")))
        let unrelated = try await receiver.capture(.init(source: .unknown, content: .text("Unrelated private history remains local")))
        let localTag = try await receiver.createTagDefinition(named: "Work", assigningTo: local.entryID).definition
        let privateTag = try await receiver.createTagDefinition(named: "Private association acceptance marker", assigningTo: local.entryID).definition
        _ = try await receiver.apply(.setTags(unrelated.entryID, [privateTag.id]))
        let definitions = [localTag, sharedTag, privateTag]
        _ = try await receiver.replaceTagDefinitions(with: definitions)

        let container = try ModelContainer(for: Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let backup = BackupService(context: container.mainContext, defaults: defaults, appPathResolver: { _ in nil },
            currentClipboardTags: { try await receiver.tagDefinitions() },
            restoreClipboardTags: { _ = try await receiver.replaceTagDefinitions(with: $0) }, reconcileRuntime: {})
        let backupURL = root.appendingPathComponent("Explicit manual backup.json")
        try await BackupCodec.encode(backup.exportCurrentSnapshot()).write(to: backupURL)
        _ = try await receiver.renameTagDefinition(id: localTag.id, to: "Changed after manual export")
        defaults.set(try ClipboardHistoryPortableSettings.encode([localTag, privateTag]),
            forKey: ClipboardHistoryPortableKeys.customTags)
        _ = try await backup.restore(BackupCodec.decode(Data(contentsOf: backupURL)))

        let restoredDefinitions = try await receiver.tagDefinitions()
        let restoredEntries = try await receiver.page(.init()).entries
        XCTAssertEqual(restoredDefinitions, definitions)
        XCTAssertNotEqual(localTag.id, sharedTag.id)
        XCTAssertEqual(Set(try XCTUnwrap(restoredEntries.first { $0.id == local.entryID }).tagIDs), [localTag.id, privateTag.id])
        XCTAssertEqual(restoredEntries.first { $0.id == unrelated.entryID }?.tagIDs, [privateTag.id])
        XCTAssertNil(defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))

        let folder = root.appendingPathComponent("Automatic Config Sync")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tagKey = SyncKey.setting(key: ClipboardHistoryPortableKeys.customTags)
        let legacyMarker = "Legacy plaintext tag acceptance marker"
        let legacyJSON = try ClipboardHistoryPortableSettings.encode([.init(id: "retired-automatic-tag", displayName: legacyMarker)])
        var oldDocument = SyncDocument(deviceID: "backup-restore-device")
        oldDocument.entries[tagKey] = SyncEntry(payload: .setting(.string(legacyJSON)),
            clock: .init(wallMillis: 2_000, counter: 0, deviceID: oldDocument.deviceID))
        let ownURL = folder.appendingPathComponent(SyncStateFile.name(forDeviceID: oldDocument.deviceID))
        let stateURL = root.appendingPathComponent("automatic-state.json")
        try SyncStateCodec.encode(oldDocument).write(to: ownURL)
        try SyncLocalStateStore(url: stateURL).save(.init(clock: SyncClock(deviceID: oldDocument.deviceID), document: oldDocument))
        var peer = SyncDocument(deviceID: "legacy-peer")
        peer.entries[tagKey] = SyncEntry(payload: .setting(.string(legacyJSON)),
            clock: .init(wallMillis: 9_000, counter: 0, deviceID: peer.deviceID))
        peer.entries[.setting(key: "menuBar.iconName")] = SyncEntry(payload: .setting(.string("backup-acceptance-peer-icon")),
            clock: .init(wallMillis: 9_000, counter: 1, deviceID: peer.deviceID))
        let peerURL = folder.appendingPathComponent(SyncStateFile.name(forDeviceID: peer.deviceID))
        let legacyPeerBytes = try SyncStateCodec.encode(peer)
        try legacyPeerBytes.write(to: peerURL)
        let engine = SyncEngine(config: .init(deviceID: oldDocument.deviceID), context: container.mainContext,
            defaults: defaults, transport: SyncFolderTransport(folderURL: folder),
            stateStore: SyncLocalStateStore(url: stateURL), reconcileRuntime: {}, wallNow: { 1_000 })
        await engine.tick()
        XCTAssertEqual(defaults.string(forKey: "menuBar.iconName"), "backup-acceptance-peer-icon", "Unrelated automatic sync must actually run")
        try assertRetiredTagChannel(defaults: defaults, ownURL: ownURL, stateURL: stateURL,
            markers: [legacyMarker, privateTag.displayName])

        try await sender.setSyncTagSelected(sharedTag.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        await sender.retrySync()
        let tagsBeforeMerge = try await receiver.syncTags()
        XCTAssertEqual(Set(tagsBeforeMerge.filter { $0.displayName == "Work" }.map(\.id)), [localTag.id, sharedTag.id])
        XCTAssertFalse(try XCTUnwrap(tagsBeforeMerge.first { $0.id == localTag.id }).isSelected)
        let beforeMerge = try await sender.page(.init()).entries
        XCTAssertEqual(beforeMerge.map(\.id), [shared.entryID], "Restoring an equal display name cannot authorize private history")

        let preview = try await receiver.prepareSyncTagMerge(sourceID: localTag.id, targetID: sharedTag.id)
        XCTAssertEqual(preview.newlyEligibleEntryCount, 1)
        let stillPrivate = try await sender.page(.init()).entries
        XCTAssertEqual(stillPrivate.map(\.id), [shared.entryID], "Displaying a merge preview must not enroll history")
        let nameOnly = try await receiver.capture(.init(source: .unknown, content: .text("A display name is not sharing consent")))
        do {
            _ = try await receiver.createTagDefinition(named: "Work", assigningTo: nameOnly.entryID)
            XCTFail("A restored name collision requires an explicit identity choice")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .duplicateTagName)
        }
        do {
            try await receiver.mergeSyncTags(preview)
            XCTFail("Changed history must invalidate the displayed merge preview")
        } catch {
            XCTAssertEqual(error as? ClipboardHistoryModuleError, .invalidConfirmation)
        }
        await sender.retrySync()
        let rejected = try await sender.page(.init()).entries
        XCTAssertEqual(rejected.map(\.id), [shared.entryID])
        let confirmed = try await receiver.prepareSyncTagMerge(sourceID: localTag.id, targetID: sharedTag.id)
        XCTAssertEqual(confirmed.newlyEligibleEntryCount, 1)
        try await receiver.mergeSyncTags(confirmed)
        await sender.retrySync()
        let sent = try await sender.page(.init()).entries
        let retained = try await receiver.page(.init()).entries
        XCTAssertEqual(Set(sent.map(\.id)), [shared.entryID, local.entryID])
        XCTAssertTrue(sent.allSatisfy { $0.tagIDs == [confirmed.canonicalTagID] })
        XCTAssertEqual(Set(try XCTUnwrap(retained.first { $0.id == local.entryID }).tagIDs), [confirmed.canonicalTagID, privateTag.id])
        XCTAssertEqual(retained.first { $0.id == unrelated.entryID }?.tagIDs, [privateTag.id])
        XCTAssertEqual(retained.first { $0.id == nameOnly.entryID }?.tagIDs, [])
        let senderDefinitions = try await sender.tagDefinitions()
        XCTAssertFalse(senderDefinitions.contains { $0.id == privateTag.id })
        let senderStatus = await sender.syncStatus()
        let receiverStatus = await receiver.syncStatus()
        XCTAssertEqual(senderStatus.phase, .upToDate)
        XCTAssertEqual(receiverStatus.phase, .upToDate)

        await engine.tick()
        try assertRetiredTagChannel(defaults: defaults, ownURL: ownURL, stateURL: stateURL,
            markers: [legacyMarker, privateTag.displayName])
        XCTAssertEqual(try Data(contentsOf: peerURL), legacyPeerBytes, "Retirement does not rewrite another device's historical file")
        let manual = try BackupCodec.decode(Data(contentsOf: backupURL))
        guard case .string(let tagJSON) = manual.settings[ClipboardHistoryPortableKeys.customTags] else {
            return XCTFail("Explicit manual backup must retain portable tag definitions")
        }
        XCTAssertEqual(try ClipboardHistoryPortableSettings.definitions(from: tagJSON), definitions)
    }

    private func assertRetiredTagChannel(defaults: UserDefaults, ownURL: URL, stateURL: URL,
        markers: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let key = SyncKey.setting(key: ClipboardHistoryPortableKeys.customTags)
        let published = try SyncStateCodec.decode(SyncDocument.self, from: Data(contentsOf: ownURL))
        let local = try XCTUnwrap(SyncLocalStateStore(url: stateURL).load(), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: ClipboardHistoryPortableKeys.customTags), file: file, line: line)
        XCTAssertNil(published.entries[key], file: file, line: line)
        XCTAssertNil(local.document.entries[key], file: file, line: line)
        for url in [ownURL, stateURL] {
            let bytes = try Data(contentsOf: url)
            for marker in markers {
                XCTAssertNil(bytes.range(of: Data(marker.utf8)), file: file, line: line)
            }
        }
    }
}
