import Foundation
import os
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testLegacyTagImportIsCancelledBeforeStoreCloseRetryOrReset() async throws {
        for action in ["close", "retry", "reset"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-tag-\(action)-\(UUID())")
            removeClipboardHistoryDirectoryAfterTest(root)
            let barrier = LinkedReplacementBarrier()
            defer { barrier.release() }
            let armed = OSAllocatedUnfairLock(initialState: false)
            let services = ClipboardSyncServices(transport: LinkedFileCloud(), keys: LinkedFileKeys(), pollingInterval: nil)
            let module = makeLinkedModule(root: root, services: services, key: 0x72, faultInjector: .init { point in
                if point == .databaseTransaction, armed.withLock({ value in
                    let held = value
                    value = false
                    return held
                }) { barrier.pause() }
                return false
            })
            armed.withLock { $0 = true }
            let importing = Task {
                try await module.importLegacyTagDefinitions(.init(format: .json,
                    data: Data("[{\"id\":\"cancelled-import\",\"name\":\"Must roll back\"}]".utf8)))
            }
            let heldDeadline = Date().addingTimeInterval(5)
            while !barrier.isWaiting, Date() < heldDeadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(barrier.isWaiting, action)
            let finished = OSAllocatedUnfairLock(initialState: false)
            let replacing = Task {
                switch action {
                case "close": try await module.closeStoreForTesting()
                case "retry": await module.retry()
                default: try await module.reset(confirmation: .confirmed)
                }
                finished.withLock { $0 = true }
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(finished.withLock { $0 }, "\(action) must drain its owned writer before replacing the pool")
            do {
                _ = try await module.importLegacyTagDefinitions(.init(format: .json, data: Data("[]".utf8)))
                XCTFail("\(action) must reject new imports while its store transition awaits the old writer")
            } catch ClipboardHistoryModuleError.operationUnavailable {}
            barrier.release()
            do {
                _ = try await importing.value
                XCTFail("\(action) must cancel the uncommitted import")
            } catch is CancellationError {}
            try await replacing.value
            let current = action == "close" ? makeLinkedModule(root: root, services: services, key: 0x72) : module
            let definitions = try await current.tagDefinitions()
            XCTAssertTrue(definitions.isEmpty, "\(action) must not publish partial definitions or the import marker")
            let result = try await current.importLegacyTagDefinitions(.init(format: .json,
                data: Data("[{\"id\":\"recovered-import\",\"name\":\"Recovered\"}]".utf8)))
            XCTAssertNil(result)
            let recovered = try await current.tagDefinitions()
            XCTAssertEqual(recovered.map(\.id), ["recovered-import"])
        }
    }

    func testLegacyTagImportRetainsInvalidOriginalBytesAcrossRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-tag-invalid-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let services = ClipboardSyncServices(transport: LinkedFileCloud(), keys: LinkedFileKeys(), pollingInterval: nil)
        let module = makeLinkedModule(root: root, services: services, key: 0x73)
        let source = ClipboardHistoryLegacyTagPreference(format: .json, data: Data("[{broken original bytes".utf8))
        let format = try await module.importLegacyTagDefinitions(source)
        XCTAssertEqual(format, .json)
        try await module.closeStoreForTesting()
        let reopened = makeLinkedModule(root: root, services: services, key: 0x73)
        let original = try await reopened.legacyTagRecovery()
        XCTAssertEqual(original, source)
        let repeated = try await reopened.importLegacyTagDefinitions(.init(format: .json, data: Data("[]".utf8)))
        XCTAssertEqual(repeated, .json)
        let retained = try await reopened.legacyTagRecovery()
        XCTAssertEqual(retained, source)
    }

    @MainActor
    func testLegacyTagImportKeepsReadsResponsiveAndQueuesOtherWriters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-tag-writer-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let services = ClipboardSyncServices(transport: LinkedFileCloud(), keys: LinkedFileKeys(), pollingInterval: nil)
        let module = makeLinkedModule(root: root, services: services, key: 0x71, faultInjector: .init { point in
            if point == .databaseTransaction, armed.withLock({ value in
                let held = value
                value = false
                return held
            }) { barrier.pause() }
            return false
        })
        let capture = try await module.capture(.init(source: .unknown, content: .text("retained local entry")))
        let existing = try await module.createTagDefinition(named: "Existing", assigningTo: capture.entryID).definition
        let records = [["id": existing.id, "name": "Stale mirror name"]]
            + (0..<500).map { ["id": "retired-\($0)", "name": "Retired \($0)"] }
        let source = ClipboardHistoryLegacyTagPreference(format: .json, data: try JSONSerialization.data(withJSONObject: records))
        armed.withLock { $0 = true }
        let importing = Task { try await module.importLegacyTagDefinitions(source) }
        let heldDeadline = Date().addingTimeInterval(5)
        while !barrier.isWaiting, Date() < heldDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(barrier.isWaiting)
        let readCompleted = OSAllocatedUnfairLock(initialState: false)
        let writerCompleted = OSAllocatedUnfairLock(initialState: false)
        let duplicateCompleted = OSAllocatedUnfairLock(initialState: false)
        let writer = Task {
            _ = try await module.apply(.setFavorite(capture.entryID, true))
            writerCompleted.withLock { $0 = true }
        }
        let duplicate = Task {
            let result = try await module.importLegacyTagDefinitions(.init(format: .json,
                data: Data("[{\"id\":\"second-import\",\"name\":\"Must not replace first import\"}]".utf8)))
            duplicateCompleted.withLock { $0 = true }
            return result
        }
        let reading = Task {
            let page = try await module.page(.init())
            let definitions = try await module.tagDefinitions()
            readCompleted.withLock { $0 = true }
            return (page, definitions)
        }
        let readDeadline = Date().addingTimeInterval(2)
        while !readCompleted.withLock({ $0 }), Date() < readDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let readBeforeRelease = readCompleted.withLock { $0 }
        XCTAssertTrue(readBeforeRelease, "The held import writer must leave the module actor and WAL reads responsive")
        XCTAssertFalse(writerCompleted.withLock { $0 })
        XCTAssertFalse(duplicateCompleted.withLock { $0 })
        barrier.release()
        let (page, beforeCommit) = try await reading.value
        if readBeforeRelease {
            XCTAssertEqual(beforeCommit, [existing])
            XCTAssertFalse(try XCTUnwrap(page.entries.first).isFavorite)
        }
        let importedFormat = try await importing.value
        let repeatedFormat = try await duplicate.value
        try await writer.value
        XCTAssertNil(importedFormat)
        XCTAssertNil(repeatedFormat)
        let definitions = try await module.tagDefinitions()
        XCTAssertEqual(definitions.count, 501)
        XCTAssertEqual(definitions.first { $0.id == existing.id }?.displayName, "Existing")
        XCTAssertFalse(definitions.contains { $0.id == "second-import" })
        let complete = try await module.page(.init())
        XCTAssertTrue(try XCTUnwrap(complete.entries.first).isFavorite)
    }
}
