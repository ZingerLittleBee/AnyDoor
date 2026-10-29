import AppKit
import Foundation
import XCTest
import os
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testCacheExhaustionKeepsHealthyFileAndTreeSourcesPendingAcrossRestart() async throws {
        for tree in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-cache-pressure-\(UUID())")
            removeClipboardHistoryDirectoryAfterTest(root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent(tree ? "Healthy tree" : "Healthy file")
            let bytes = Data(repeating: 0x5A, count: tree ? 64 : 5_000_001)
            if tree { try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true) }
            let member = tree ? source.appendingPathComponent("member.txt") : source
            try bytes.write(to: member)
            let pressure = OSAllocatedUnfairLock(initialState: (armed: false, fails: false, attempts: 0))
            let faults = ClipboardHistoryFaultInjector { point in
                guard point == .diskFull else { return false }
                return pressure.withLock { state in
                    guard state.armed else { return false }
                    state.attempts += 1
                    return state.fails
                }
            }
            let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000))
            let cloud = LinkedFileCloud()
            let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
            let senderRoot = root.appendingPathComponent("Sender")
            let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: senderRoot,
                keyStore: FreezeCacheLocalKey(), faultInjector: faults, now: { clock.withLock { $0 } }, syncServices: services))
            let receiver = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0xB6)
            let removed = try await sender.capture(.init(source: .unknown, content: .text("delete despite cache pressure")))
            let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: removed.entryID)
            try await sender.setSyncTagSelected(tag.definition.id, selected: true)
            try await sender.setSyncEnabled(true)
            try await receiver.setSyncEnabled(true)
            try await sender.setSyncEnabled(false)
            let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.freeze-cache.\(UUID())"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.setString(source.absoluteString, forType: .fileURL)
            guard case .captured(let captured) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
                return XCTFail("Expected an owned readable source reference")
            }
            _ = try await sender.apply(.setTags(captured.entryID, [tag.definition.id]))
            let added = try await sender.capture(.init(source: .unknown, content: .text("upload despite cache pressure")))
            _ = try await sender.apply(.setTags(added.entryID, [tag.definition.id]))
            _ = try await sender.apply(.delete(removed.entryID))
            pressure.withLock { $0.armed = true; $0.fails = true }
            try await sender.setSyncEnabled(true)
            let failed = await sender.syncStatus()
            XCTAssertEqual(failed.phase, .failed(.localStorage))
            let local = try await sender.page(.init())
            let localFile = try XCTUnwrap(local.entries.first { $0.id == captured.entryID }?.syncFiles.first)
            XCTAssertEqual(localFile.state, .waitingForUpload)
            XCTAssertEqual(localFile.transferFailure, .localStorage)
            XCTAssertTrue(localFile.uploadPending)
            XCTAssertNil(localFile.availableVersionID)
            XCTAssertEqual(try Data(contentsOf: member), bytes)
            await receiver.retrySync()
            let remote = try await receiver.page(.init())
            XCTAssertTrue(remote.entries.contains { $0.id == added.entryID })
            XCTAssertFalse(remote.entries.contains { $0.id == removed.entryID })
            let pending = try XCTUnwrap(remote.entries.first { $0.id == captured.entryID }?.syncFiles.first)
            XCTAssertEqual(pending.state, .waitingForUpload, "Cache exhaustion must not claim the healthy source is unavailable")
            XCTAssertNil(pending.availableVersionID)
            let uploads = await cloud.uploadedRecords()
            XCTAssertFalse(uploads.contains { $0.record.kind == .fileBody }, "No incomplete frozen body can be published")
            let failedAttempts = pressure.withLock { $0.attempts }
            XCTAssertEqual(failedAttempts, 1)
            try await sender.closeStoreForTesting()
            pressure.withLock { $0.fails = false }
            let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: senderRoot,
                keyStore: FreezeCacheLocalKey(), faultInjector: faults, now: { clock.withLock { $0 } }, syncServices: services))
            await reopened.resumeSync()
            XCTAssertEqual(pressure.withLock { $0.attempts }, failedAttempts, "Automatic reopen must retain the source retry deadline")
            await reopened.retrySync()
            XCTAssertGreaterThan(pressure.withLock { $0.attempts }, failedAttempts)
            await receiver.retrySync()
            let ready = try await receiver.page(.init())
            let downloadable = try XCTUnwrap(ready.entries.first { $0.id == captured.entryID }?.syncFiles.first)
            if downloadable.state == .waitingForDownload {
                try await receiver.requestSyncFileDownload(entryID: captured.entryID, objectID: downloadable.id,
                    versionID: downloadable.versionID)
            }
            let materialized = try await receiver.materialize(.init(entryID: captured.entryID, purpose: .normalPaste))
            guard case .file(let file) = materialized.items.first?.representations.first else {
                return XCTFail("Expected a complete recovered file")
            }
            let received = tree ? file.currentURL.appendingPathComponent("member.txt") : file.currentURL
            XCTAssertEqual(try Data(contentsOf: received), bytes)
            let recovered = try await reopened.page(.init())
            let recoveredFile = try XCTUnwrap(recovered.entries.first { $0.id == captured.entryID }?.syncFiles.first)
            XCTAssertNil(recoveredFile.transferFailure)
            XCTAssertEqual(try Data(contentsOf: member), bytes)
        }
    }
}

private struct FreezeCacheLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0xB5, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}
