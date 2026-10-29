import AppKit
import CryptoKit
import Darwin
import Foundation
import XCTest
import os

@testable import ClipboardHistory

private struct WorkingOutputStoreKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x52, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testStoreReplacementCreatesMissingExclusiveLeaseBeforeDiscard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("working-output-missing-lock-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let locked = OSAllocatedUnfairLock(initialState: false)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: WorkingOutputStoreKey(), faultInjector: .init { point in
                guard point == .legacyMigrationBeforePublication else { return false }
                let fd = open(root.appendingPathComponent("working-output.lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
                if fd >= 0 {
                    defer { close(fd) }
                    locked.withLock { $0 = flock(fd, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK }
                }
                return true
            }))
        _ = try await module.workingOutputRecoveries()
        let entry = try await module.capture(.init(source: .unknown, content: .text("keep until verified replacement")))
        try FileManager.default.removeItem(at: root.appendingPathComponent("working-output.lock"))
        let request = ClipboardHistoryLegacyMigrationRequest(transfer: .init(entries: [], tags: [],
            categoryOrder: [], retentionPeriod: .thirtyDays), payloadDirectory: root)
        do {
            _ = try await module.migrateLegacy(request, discardingEntries: 1)
            XCTFail("Expected the actual publication boundary fault")
        } catch { XCTAssertEqual(error as? ClipboardHistoryModuleError, .legacyMigrationFailed) }
        XCTAssertTrue(locked.withLock { $0 }, "An absent sidecar must not bypass store replacement exclusion")
        let page = try await module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [entry.entryID])
    }

    @MainActor
    func testStoreReplacementPreservesUnexpectedLockFileContentsAndKinds() async throws {
        for kind in ["file", "directory", "symlink"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("working-output-lock-\(UUID())")
            removeClipboardHistoryDirectoryAfterTest(root)
            let store = root.appendingPathComponent("Store")
            let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: store,
                keyStore: WorkingOutputStoreKey()))
            _ = try await module.workingOutputRecoveries()
            try await module.closeStoreForTesting()
            let lock = store.appendingPathComponent("working-output.lock")
            try FileManager.default.removeItem(at: lock)
            let sentinel = root.appendingPathComponent("keep.txt")
            let bytes = Data("unowned lock-name occupant".utf8)
            try bytes.write(to: sentinel)
            switch kind {
            case "file": try bytes.write(to: lock)
            case "directory":
                try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                try bytes.write(to: lock.appendingPathComponent("member.txt"))
            default: try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: sentinel)
            }
            let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: store,
                keyStore: WorkingOutputStoreKey()))
            let request = ClipboardHistoryLegacyMigrationRequest(transfer: .init(entries: [], tags: [],
                categoryOrder: [], retentionPeriod: .thirtyDays), payloadDirectory: root)
            do {
                _ = try await reopened.migrateLegacy(request)
                XCTFail("An unexpected lock-name occupant must prevent replacement: \(kind)")
            } catch {}
            try await reopened.closeStoreForTesting()
            XCTAssertEqual(try Data(contentsOf: sentinel), bytes)
            if kind == "directory" { XCTAssertEqual(try Data(contentsOf: lock.appendingPathComponent("member.txt")), bytes) }
            else { XCTAssertEqual(try Data(contentsOf: lock), bytes) }
            if kind == "symlink" { XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lock.path), sentinel.path) }
        }
    }

    @MainActor
    func testPendingWorkingOutputPreventsLegacyMigrationAndEmptyStoreAdoption() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("working-output-store-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x51)
        let target = root.appendingPathComponent("Current")
        let working = root.appendingPathComponent("Visible")
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: target,
            keyStore: WorkingOutputStoreKey(), faultInjector: .init { $0 == .syncWorkingOutputDuringConstruction },
            syncServices: services, testingSyncWorkingRoot: working))
        let source = root.appendingPathComponent("source.txt")
        let bytes = Data("pending output retains durable ownership".utf8)
        try bytes.write(to: source)
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.working-output-store.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let captured) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected file capture")
        }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await module.setSyncEnabled(true)
        try await module.setSyncEnabled(false)
        let notices = try await module.workingOutputRecoveries()
        let notice = try XCTUnwrap(notices.first)
        _ = try await module.apply(.delete(captured.entryID))
        let empty = try await module.page(.init())
        XCTAssertTrue(empty.entries.isEmpty)
        try await module.closeStoreForTesting()
        let transferCache = target.appendingPathComponent("SyncTransfers")
        if FileManager.default.fileExists(atPath: transferCache.path) { try FileManager.default.removeItem(at: transferCache) }
        let children = try FileManager.default.contentsOfDirectory(atPath: target.path)
        XCTAssertTrue(Set(children).isSubset(of: ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm",
            "payloads", "staging", "working-output.lock"]), "Only pending ownership may prevent empty-store adoption")
        let migrationModule = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: target,
            keyStore: WorkingOutputStoreKey(), syncServices: services, testingSyncWorkingRoot: working))
        let request = ClipboardHistoryLegacyMigrationRequest(transfer: .init(entries: [], tags: [],
            categoryOrder: [], retentionPeriod: .thirtyDays), payloadDirectory: root)
        do {
            _ = try await migrationModule.migrateLegacy(request)
            XCTFail("An entry count cannot authorize discarding external output ownership")
        } catch { XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable) }
        try await migrationModule.closeStoreForTesting()
        let legacyRoot = root.appendingPathComponent("Legacy")
        let legacy = makeLinkedModule(root: legacyRoot, services: services, key: 0x52)
        _ = try await legacy.capture(.init(source: .unknown, content: .text("displaced history must remain archived")))
        try await legacy.closeStoreForTesting()
        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: target,
            legacyStoreRoot: legacyRoot, keyStore: WorkingOutputStoreKey(), syncServices: services,
            testingSyncWorkingRoot: working))
        let retained = try await reopened.workingOutputRecoveries()
        XCTAssertEqual(retained.map(\.id), [notice.id])
        XCTAssertEqual(try Data(contentsOf: notice.url), bytes)
        let page = try await reopened.page(.init())
        XCTAssertTrue(page.entries.isEmpty, "Pending ownership makes this store nonempty for adoption")
    }

    @MainActor
    func testLegacyInlineConstructionIsRevokedByOffAndRecoversAfterReview() async throws {
        let barrier = LinkedReplacementBarrier()
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncWorkingOutputDuringConstruction, armed.withLock({ $0 }) { barrier.pause() }
            return false
        })
        addTeardownBlock { barrier.release() }
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try await fixture.receiver.setSyncEnabled(false)
        let account = await fixture.cloud.account()
        let observed = await fixture.cloud.control(for: account)
        let control = try XCTUnwrap(observed)
        let loaded = try await fixture.services.keys.load(account: account, keyID: control.keyID)
        let key = try XCTUnwrap(loaded)
        let bytes = Data(repeating: 0x68, count: 128 * 1_024)
        let version = UUID()
        let body = try ClipboardSyncCodec.seal(.fileBody(.init(objectID: working.objectID, versionID: version, bytes: bytes)),
            account: account, control: control, key: key, operationID: version)
        let descriptor = ClipboardSyncFileDescriptor(objectID: working.objectID, versionID: version,
            displayName: fixture.original.lastPathComponent, originalByteCount: Int64(bytes.count),
            contentDigest: Data(SHA256.hash(data: bytes)), body: body.record, state: .available)
        let metadata = try ClipboardSyncCodec.seal(.fileVersion(.init(descriptor: descriptor, parents: [working.baseVersionID])),
            account: account, control: control, key: key)
        let afterBody = try await fixture.cloud.commit(body, for: account, control: control)
        _ = try await fixture.cloud.commit(metadata, for: account, control: afterBody)
        armed.withLock { $0 = true }
        let receiving = Task { try await fixture.receiver.setSyncEnabled(true) }
        try await eventually { barrier.isWaiting }
        let cancellations = await fixture.cloud.cancellationCount()
        let disable = Task { try await fixture.receiver.setSyncEnabled(false) }
        try await eventually { await fixture.cloud.cancellationCount() > cancellations }
        barrier.release()
        try await disable.value
        try await receiving.value
        XCTAssertEqual(try Data(contentsOf: working.url), Data("initial linked bytes".utf8))
        let status = await fixture.receiver.syncStatus()
        XCTAssertFalse(status.isEnabled)
        let pending = try await fixture.receiver.workingOutputRecoveries()
        let notice = try XCTUnwrap(pending.first)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(notice.reason, .incomplete)
        let incomplete = try Data(contentsOf: notice.url)
        XCTAssertEqual(incomplete, bytes.prefix(64 * 1_024))
        XCTAssertFalse(FileManager.default.fileExists(atPath: notice.url.deletingLastPathComponent()
            .appendingPathComponent(fixture.original.lastPathComponent).path))
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let retained = try await reopened.workingOutputRecoveries()
        XCTAssertEqual(retained.map(\.id), [notice.id])
        try await reopened.keepWorkingOutput(notice.id)
        try await reopened.setSyncEnabled(true)
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Expected recovered inline file") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL), bytes)
        XCTAssertEqual(try Data(contentsOf: notice.url), incomplete)
    }

    @MainActor
    func testRepeatedConstructionFailureKeepsOneNoticeWhileIndependentSyncContinues() async throws {
        let failures = OSAllocatedUnfairLock(initialState: (enabled: true, writes: 0))
        let faults = ClipboardHistoryFaultInjector { point in
            guard point == .syncWorkingOutputDuringConstruction else { return false }
            return failures.withLock { state in state.writes += 1; return state.enabled }
        }
        let fixture = try await makeLinkedFixture(receiverFault: faults, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("incomplete construction stays visible".utf8).write(to: root.appendingPathComponent("member.txt"))
        })
        let initial = try await fixture.receiver.workingOutputRecoveries()
        let notice = try XCTUnwrap(initial.first)
        XCTAssertEqual(initial.count, 1)
        let bytes = try Data(contentsOf: notice.url.appendingPathComponent("member.txt"))
        let choices = try await fixture.receiver.syncTags()
        let tag = try XCTUnwrap(choices.first)
        try await fixture.receiver.setSyncTagSelected(tag.id, selected: true)
        let removed = try await fixture.receiver.capture(.init(source: .unknown, content: .text("delete beside a pending working output")))
        _ = try await fixture.receiver.apply(.setTags(removed.entryID, [tag.id]))
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        try await fixture.receiver.setSyncEnabled(false)
        let independent = try await fixture.receiver.capture(.init(source: .unknown, content: .text("independent sharing continues")))
        _ = try await fixture.receiver.apply(.setTags(independent.entryID, [tag.id]))
        _ = try await fixture.receiver.apply(.delete(removed.entryID))
        try await fixture.receiver.setSyncEnabled(true)
        for _ in 0..<4 { await fixture.receiver.retrySync() }
        await fixture.sender.retrySync()
        let peer = try await fixture.sender.page(.init()).entries
        XCTAssertTrue(peer.contains { $0.id == independent.entryID })
        XCTAssertFalse(peer.contains { $0.id == removed.entryID })
        let retained = try await fixture.receiver.workingOutputRecoveries()
        XCTAssertEqual(retained.map(\.id), [notice.id])
        XCTAssertEqual(failures.withLock { $0.writes }, 1, "Retry must not start another incomplete output for this version")
        let children = try FileManager.default.contentsOfDirectory(at: notice.url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        XCTAssertEqual(children.filter { $0.lastPathComponent.hasPrefix("Receiving-") }.count, 1)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52, faultInjector: faults)
        await reopened.resumeSync()
        for _ in 0..<3 { await reopened.retrySync() }
        let afterRestart = try await reopened.workingOutputRecoveries()
        XCTAssertEqual(afterRestart.map(\.id), [notice.id])
        XCTAssertEqual(failures.withLock { $0.writes }, 1)
        failures.withLock { $0.enabled = false }
        try await reopened.keepWorkingOutput(notice.id)
        await reopened.retrySync()
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Expected complete retried tree") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member.txt")), bytes)
        XCTAssertEqual(try Data(contentsOf: notice.url.appendingPathComponent("member.txt")), bytes,
            "Keep relinquishes the old candidate instead of deleting it")
        let complete = try await reopened.workingOutputRecoveries()
        XCTAssertTrue(complete.isEmpty)
    }

    @MainActor
    func testAnotherProcessCannotReclaimAnActiveReceivingOutput() async throws {
        if let childRoot = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await createInterruptedWorkingOutput(at: URL(fileURLWithPath: childRoot))
            return XCTFail("Expected held construction crash")
        }
        let root = try workingOutputScenario(kind: "tree", stage: "held")
        defer { try? Data().write(to: root.appendingPathComponent("release")) }
        async let result = WorkingOutputCrash.run(root: root, bundle: Bundle(for: Self.self).bundleURL,
            test: "ClipboardHistoryLinkedFileTests/testAnotherProcessCannotReclaimAnActiveReceivingOutput")
        try await eventually { FileManager.default.fileExists(atPath: root.appendingPathComponent("pending-path").path) }
        let pending = try workingOutputPath(in: root)
        let services = try await restoreWorkingOutputServices(in: root)
        let module = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
        let active = try await module.workingOutputRecoveries()
        XCTAssertTrue(active.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent("member.txt").path))
        let count = try await module.page(.init()).entries.count
        let request = ClipboardHistoryLegacyMigrationRequest(transfer: .init(entries: [], tags: [],
            categoryOrder: [], retentionPeriod: .thirtyDays), payloadDirectory: root)
        do {
            _ = try await module.migrateLegacy(request, discardingEntries: count)
            XCTFail("Store replacement must not unlink another process's active lease")
        } catch { XCTAssertEqual(error as? ClipboardHistoryModuleError, .operationUnavailable) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.appendingPathComponent("member.txt").path))
        try Data().write(to: root.appendingPathComponent("release"))
        let exited = try await result
        XCTAssertEqual(exited.status, 73, exited.output)
        let recovered = try await module.workingOutputRecoveries()
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    @MainActor
    func testIncompleteWorkingOutputIsDiscoverableAcrossOffRestartAndKeep() async throws {
        if let childRoot = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await createInterruptedWorkingOutput(at: URL(fileURLWithPath: childRoot))
            return XCTFail("Expected owned construction crash")
        }
        for kind in ["tree", "raw"] {
            let root = try workingOutputScenario(kind: kind, stage: "middle")
            let result = try await WorkingOutputCrash.run(root: root, bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testIncompleteWorkingOutputIsDiscoverableAcrossOffRestartAndKeep")
            XCTAssertEqual(result.status, 73, result.output)
            guard result.status == 73 else { continue }
            let pending = try workingOutputPath(in: root)
            let member = kind == "tree" ? pending.appendingPathComponent("member.txt") : pending
            let bytes = try Data(contentsOf: member)
            XCTAssertFalse(bytes.isEmpty)
            let services = try await restoreWorkingOutputServices(in: root)
            let module = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            try await module.setSyncEnabled(false)
            let initial = try await module.workingOutputRecoveries()
            let notice = try XCTUnwrap(initial.first)
            XCTAssertEqual(initial.count, 1)
            XCTAssertEqual(notice.reason, .incomplete)
            XCTAssertEqual(notice.url.resolvingSymlinksInPath(), pending.resolvingSymlinksInPath())
            XCTAssertEqual(try Data(contentsOf: member), bytes)
            try await module.closeStoreForTesting()
            let reopened = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            let retained = try await reopened.workingOutputRecoveries()
            XCTAssertEqual(retained.map(\.id), [notice.id])
            for _ in 0..<3 { await reopened.retrySync() }
            XCTAssertEqual(try Data(contentsOf: member), bytes)
            try await reopened.keepWorkingOutput(notice.id)
            try await reopened.keepWorkingOutput(notice.id)
            let kept = try await reopened.workingOutputRecoveries()
            XCTAssertTrue(kept.isEmpty)
            XCTAssertEqual(try Data(contentsOf: member), bytes)
            try await reopened.closeStoreForTesting()
            let final = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            let dismissed = try await final.workingOutputRecoveries()
            XCTAssertTrue(dismissed.isEmpty)
            XCTAssertEqual(try Data(contentsOf: member), bytes)
        }
    }

    @MainActor
    func testChangedReceivingOutputAndReplacedParentNeverAuthorizeDeletion() async throws {
        if let childRoot = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await createInterruptedWorkingOutput(at: URL(fileURLWithPath: childRoot))
            return XCTFail("Expected pre-publication crash")
        }
        for change in ["member", "root", "parent", "extra"] {
            let root = try workingOutputScenario(kind: "tree", stage: "before")
            let result = try await WorkingOutputCrash.run(root: root, bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testChangedReceivingOutputAndReplacedParentNeverAuthorizeDeletion")
            XCTAssertEqual(result.status, 73, result.output)
            guard result.status == 73 else { continue }
            let pending = try workingOutputPath(in: root)
            let changed = Data("user material must survive \(change)".utf8)
            var preserved = pending.appendingPathComponent("member.txt")
            if change == "root" {
                try FileManager.default.moveItem(at: pending, to: pending.appendingPathExtension("kept"))
                try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
            } else if change == "parent" {
                let parent = pending.deletingLastPathComponent()
                try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("kept"))
                try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
            } else if change == "extra" { preserved = pending.appendingPathComponent("unexplained.txt") }
            try changed.write(to: preserved)
            let services = try await restoreWorkingOutputServices(in: root)
            let module = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            let notices = try await module.workingOutputRecoveries()
            XCTAssertEqual(notices.count, 1)
            XCTAssertEqual(notices.first?.reason, .changed)
            XCTAssertEqual(try Data(contentsOf: preserved), changed)
            if change == "member", geteuid() != 0 {
                XCTAssertEqual(chmod(preserved.path, 0), 0)
                for _ in 0..<3 {
                    let refreshed = try await module.workingOutputRecoveries()
                    XCTAssertEqual(refreshed.first?.reason, .changed,
                        "Persisted review notices must not re-read now-inaccessible file bodies")
                }
                XCTAssertEqual(chmod(preserved.path, 0o600), 0)
            }
            await module.resumeSync()
            await module.retrySync()
            XCTAssertEqual(try Data(contentsOf: preserved), changed)
            let remaining = try await module.workingOutputRecoveries()
            XCTAssertEqual(remaining.map(\.id), notices.map(\.id))
        }
    }

    @MainActor
    func testPublishedAndRenamedOutputsAreNotFollowedByRecovery() async throws {
        if let childRoot = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await createInterruptedWorkingOutput(at: URL(fileURLWithPath: childRoot))
            return XCTFail("Expected publication checkpoint crash")
        }
        for stage in ["after", "before"] {
            let root = try workingOutputScenario(kind: "tree", stage: stage)
            let result = try await WorkingOutputCrash.run(root: root, bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testPublishedAndRenamedOutputsAreNotFollowedByRecovery")
            XCTAssertEqual(result.status, 73, result.output)
            guard result.status == 73 else { continue }
            let output = try workingOutputPath(in: root)
            let retained = stage == "before" ? output.appendingPathExtension("user-kept") : output
            if stage == "before" { try FileManager.default.moveItem(at: output, to: retained) }
            let bytes = try Data(contentsOf: retained.appendingPathComponent("member.txt"))
            let services = try await restoreWorkingOutputServices(in: root)
            let module = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            let notices = try await module.workingOutputRecoveries()
            XCTAssertTrue(notices.isEmpty)
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("member.txt")), bytes)
            await module.resumeSync()
            await module.retrySync()
            let page = try await module.page(.init()).entries
            let entry = try XCTUnwrap(page.first)
            let materialized = try await module.materialize(.init(entryID: entry.id, purpose: .normalPaste))
            guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Expected complete recovered tree") }
            XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member.txt")), bytes)
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("member.txt")), bytes)
        }
    }

    @MainActor
    func testRestartReclaimsOnlyOwnedUnchangedReceivingOutputs() async throws {
        if let childRoot = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await createInterruptedWorkingOutput(at: URL(fileURLWithPath: childRoot))
            return XCTFail("The construction checkpoint must exit without unwinding")
        }
        for (kind, stage) in [("tree", "before"), ("raw", "before"), ("tree", "owned"), ("raw", "owned")] {
            let root = try workingOutputScenario(kind: kind, stage: stage)
            let result = try await WorkingOutputCrash.run(root: root, bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testRestartReclaimsOnlyOwnedUnchangedReceivingOutputs")
            XCTAssertEqual(result.status, 73, result.output)
            guard result.status == 73 else { continue }
            let pending = URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("pending-path"), encoding: .utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
            let sibling = pending.deletingLastPathComponent()
            let unrelated = sibling.appendingPathComponent("Receiving-unowned.partial")
            let displaced = sibling.appendingPathComponent("Notes (AnyDoor update retained)")
            try Data("unowned user material".utf8).write(to: unrelated)
            try Data("retained editor output".utf8).write(to: displaced)
            let services = ClipboardSyncServices(transport: LinkedFileCloud(), keys: LinkedFileKeys(), pollingInterval: nil)
            let reopened = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52)
            await reopened.resumeSync()
            let recoveries = try await reopened.workingOutputRecoveries()
            XCTAssertTrue(recoveries.isEmpty, "Unchanged complete output should be reclaimed: \(recoveries)")
            try await eventually { !FileManager.default.fileExists(atPath: pending.path) }
            XCTAssertEqual(try Data(contentsOf: unrelated), Data("unowned user material".utf8))
            XCTAssertEqual(try Data(contentsOf: displaced), Data("retained editor output".utf8))
            try await reopened.closeStoreForTesting()
        }
    }

    @MainActor
    private func createInterruptedWorkingOutput(at root: URL) async throws {
        let kind = try String(contentsOf: root.appendingPathComponent("kind"), encoding: .utf8)
        let stage = (try? String(contentsOf: root.appendingPathComponent("stage"), encoding: .utf8)) ?? "before"
        let source = root.appendingPathComponent(kind == "tree" ? "Notes" : "Notes.txt")
        if kind == "tree" {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            try Data("owned complete member".utf8).write(to: source.appendingPathComponent("member.txt"))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: source.path)
        } else { try Data("owned complete raw file".utf8).write(to: source) }
        let cloud = LinkedFileCloud(), keys = LinkedFileKeys()
        let services = ClipboardSyncServices(transport: cloud, keys: keys, pollingInterval: nil)
        let sender = makeLinkedModule(root: root.appendingPathComponent("Sender"), services: services, key: 0x51)
        let receiverRoot = root.appendingPathComponent("Receiver")
        let receiver = makeLinkedModule(root: receiverRoot, services: services, key: 0x52, faultInjector: .init { point in
            let checkpoint: ClipboardHistoryFaultPoint = stage == "middle" ? .syncWorkingOutputDuringConstruction
                : stage == "after" ? .syncFileAfterPublication
                : stage == "owned" ? .syncWorkingOutputAfterOwnership : .syncFileBeforePublication
            guard point == checkpoint else { return false }
            let working = receiverRoot.appendingPathComponent("Linked Working Copies")
            let paths = FileManager.default.enumerator(at: working, includingPropertiesForKeys: nil)
            while let url = paths?.nextObject() as? URL {
                let matches = stage == "after" ? url.lastPathComponent == source.lastPathComponent
                    : url.lastPathComponent.hasPrefix("Receiving-") && url.pathExtension == "partial"
                if matches {
                    do { try Data(url.path.utf8).write(to: root.appendingPathComponent("pending-path"), options: .atomic) }
                    catch { _exit(74) }
                    if stage == "held" {
                        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("release").path) { usleep(10_000) }
                    }
                    _exit(73)
                }
            }
            _exit(75)
        })
        let board = NSPasteboard(name: .init("dev.bybee.AnyDoor.working-output.\(UUID())"))
        board.setString(source.absoluteString, forType: .fileURL)
        let captured = try await sender.capture(.init(pasteboard: board), source: .unknown)
        board.releaseGlobally()
        guard case .captured(let entry) = captured else { return XCTFail("Expected real file capture") }
        let tag = try await sender.createTagDefinition(named: "Shared", assigningTo: entry.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        let account = await cloud.account()
        let observed = await cloud.control(for: account)
        let control = try XCTUnwrap(observed)
        let sharedKey = await keys.load(account: account, keyID: control.keyID)
        let transcript = WorkingOutputTranscript(control: control, key: try XCTUnwrap(sharedKey), uploads: await cloud.uploadedRecords())
        try JSONEncoder().encode(transcript).write(to: root.appendingPathComponent("external-transcript"))
        try await receiver.setSyncEnabled(true)
    }

    private func workingOutputScenario(kind: String, stage: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("working-output-recovery-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(kind.utf8).write(to: root.appendingPathComponent("kind"))
        try Data(stage.utf8).write(to: root.appendingPathComponent("stage"))
        return root
    }

    private func workingOutputPath(in root: URL) throws -> URL {
        URL(fileURLWithPath: try String(contentsOf: root.appendingPathComponent("pending-path"), encoding: .utf8))
    }

    @MainActor
    private func restoreWorkingOutputServices(in root: URL) async throws -> ClipboardSyncServices {
        let transcript = try JSONDecoder().decode(WorkingOutputTranscript.self,
            from: Data(contentsOf: root.appendingPathComponent("external-transcript")))
        let cloud = LinkedFileCloud(), keys = LinkedFileKeys()
        let account = await cloud.account()
        _ = await cloud.createControl(transcript.control, for: account)
        _ = try await keys.create(account: account, keyID: transcript.control.keyID, key: transcript.key)
        await cloud.replayLateRecords(transcript.uploads)
        return .init(transport: cloud, keys: keys, pollingInterval: nil)
    }
}

private struct WorkingOutputTranscript: Codable, Sendable {
    let control: ClipboardSyncControl
    let key: Data
    let uploads: [ClipboardSyncUpload]
}

private enum WorkingOutputCrash {
    static let rootKey = "ANYDOOR_WORKING_OUTPUT_TEST_ROOT"
    struct Result: Sendable { let status: Int32; let output: String }

    @concurrent static func run(root: URL, bundle: URL, test: String) async throws -> Result {
        let scratch = root.appendingPathComponent("Scratch")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        let log = root.appendingPathComponent("child.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).resolvingSymlinksInPath()
        process.arguments = ["-XCTest", test, bundle.path]
        var environment = ProcessInfo.processInfo.environment
        environment[rootKey] = root.path
        environment["TMPDIR"] = scratch.path + "/"
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        return .init(status: process.terminationReason == .exit ? process.terminationStatus : -1,
            output: try String(contentsOf: log, encoding: .utf8))
    }
}
