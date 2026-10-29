import AppKit
import Foundation
import GRDB
import os
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testNativeDisplayTimeoutReturnsLatestPageAndCommittedMutationWithoutAnotherWorker() async throws {
        let waiting = NativeDisplayWaitController()
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let observation = OSAllocatedUnfairLock(initialState: (armed: false, calls: 0))
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: waiting.policy) { point in
            guard point == .pageNativeFileFacts || point == .entryNativeFileFacts else { return false }
            let first = observation.withLock { value in
                guard value.armed else { return false }
                value.calls += 1
                return value.calls == 1
            }
            if first { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        let deleted = try await fixture.receiver.capture(.init(source: .unknown, content: .text("old snapshot entry")))
        observation.withLock { $0.armed = true }
        waiting.arm()
        let pageRequest = Task { try await fixture.receiver.page(.init()) }
        try await eventually { barrier.isWaiting && waiting.admissions == 1 }
        let mutation = Task { try await fixture.receiver.apply(.setFavorite(fixture.entryID, true)) }
        try await eventually { waiting.admissions == 2 }
        _ = try await fixture.receiver.apply(.delete(deleted.entryID))
        let fresh = try await fixture.receiver.capture(.init(source: .unknown, content: .text("current SQL entry")))
        waiting.expireAll()
        let page = try await pageRequest.value
        XCTAssertFalse(page.entries.contains { $0.id == deleted.entryID })
        XCTAssertTrue(page.entries.contains { $0.id == fresh.entryID })
        XCTAssertEqual(page.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.state, .localUnavailable)
        guard case .updated(let entry) = try await mutation.value else { return XCTFail("Committed favorite must return") }
        XCTAssertTrue(entry.isFavorite)
        XCTAssertEqual(entry.syncFiles.first?.state, .localUnavailable)
        XCTAssertEqual(waiting.pendingTimeouts, 0)
        XCTAssertEqual(observation.withLock { $0.calls }, 1, "Timeout must not create a replacement native worker")
        let next = Task { try await fixture.receiver.page(.init()) }
        try await eventually { waiting.admissions == 3 }
        waiting.expireAll()
        let nextPage = try await next.value
        XCTAssertEqual(nextPage.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.state, .localUnavailable)
        XCTAssertEqual(observation.withLock { $0.calls }, 1)
        let textPage = try await fixture.receiver.page(.init(facet: .text))
        XCTAssertTrue(textPage.entries.contains { $0.id == fresh.entryID })
        XCTAssertEqual(waiting.admissions, 3)
        barrier.release()
        let recovered = try await fixture.receiver.page(.init())
        XCTAssertEqual(recovered.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.state, .complete)
        XCTAssertEqual(waiting.pendingTimeouts, 0)
    }

    @MainActor
    func testNativeDisplayTimeoutStillRejectsAReopenedStore() async throws {
        let waiting = NativeDisplayWaitController()
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: waiting.policy) { point in
            if point == .pageNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        armed.withLock { $0 = true }
        waiting.arm()
        let request = Task { try await fixture.receiver.page(.init()) }
        try await eventually { barrier.isWaiting && waiting.admissions == 1 }
        await fixture.receiver.retry()
        waiting.expireAll()
        do { _ = try await request.value; XCTFail("Timeout cannot authorize a retired pool") }
        catch ClipboardHistoryModuleError.storeUnavailable {}
        armed.withLock { $0 = false }
        barrier.release()
    }

    @MainActor
    func testNativeDisplayTimeoutDoesNotRestoreADeletedMutationTarget() async throws {
        let waiting = NativeDisplayWaitController()
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: waiting.policy) { point in
            if point == .entryNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        armed.withLock { $0 = true }
        waiting.arm()
        let request = Task { try await fixture.receiver.apply(.setFavorite(fixture.entryID, true)) }
        try await eventually { barrier.isWaiting && waiting.admissions == 1 }
        _ = try await fixture.receiver.apply(.delete(fixture.entryID))
        waiting.expireAll()
        let result = try await request.value
        XCTAssertEqual(result, .notFound)
        armed.withLock { $0 = false }
        barrier.release()
    }

    @MainActor
    func testPageCoalescingSeparatesRetentionSnapshotsWithoutAWrite() async throws {
        let waiting = NativeDisplayWaitController()
        let fixture = try await makeLinkedFixture()
        await fixture.sender.suspendSync()
        try await fixture.receiver.closeStoreForTesting()
        let clock = OSAllocatedUnfairLock(initialState: Date())
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let observation = OSAllocatedUnfairLock(initialState: (armed: false, calls: 0))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: fixture.receiverRoot,
            keyStore: NativeDisplayTestKey(), faultInjector: .init(nativeDisplayWaiting: waiting.policy) { point in
                guard point == .pageNativeFileFacts else { return false }
                let first = observation.withLock { value in
                    guard value.armed else { return false }
                    value.calls += 1
                    return value.calls == 1
                }
                if first { barrier.pause() }
                return false
            }, now: { clock.withLock { $0 } }, syncServices: fixture.services))
        await receiver.suspendSync()
        let text = try await receiver.capture(.init(source: .unknown, content: .text("expires while native work waits")))
        let observer = try await receiver.requiredDatabase()
        let revisionBefore = try await observer.read { try ClipboardHistoryModule.historyRevision(in: $0) }
        observation.withLock { $0.armed = true }
        waiting.arm()
        let old = Task { try await receiver.page(.init()) }
        try await eventually { barrier.isWaiting }
        clock.withLock { $0 = $0.addingTimeInterval(31 * 86_400) }
        let remaining = try await receiver.count(.init())
        XCTAssertEqual(remaining, 1, "Only the protected file remains live, without a database mutation")
        let revisionAfterClock = try await observer.read { try ClipboardHistoryModule.historyRevision(in: $0) }
        XCTAssertEqual(revisionAfterClock, revisionBefore)
        let fresh = Task { try await receiver.page(.init()) }
        try await eventually { waiting.admissions == 2 }
        barrier.release()
        _ = try await old.value
        let page = try await fresh.value
        XCTAssertFalse(page.entries.contains { $0.id == text.entryID })
        XCTAssertEqual(page.entries.map(\.id), [fixture.entryID])
        XCTAssertEqual(observation.withLock { $0.calls }, 2)
        let revisionAfterPages = try await observer.read { try ClipboardHistoryModule.historyRevision(in: $0) }
        XCTAssertEqual(revisionAfterPages, revisionBefore, "A background write must not supply the invalidation in this test")
    }

    @MainActor
    func testCancelledMultiFilePageStopsBeforeTheRemainingNativeProbes() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let observation = OSAllocatedUnfairLock(initialState: (armed: false, jobs: 0, probes: 0))
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
            let pause = observation.withLock { value -> Bool in
                guard value.armed else { return false }
                if point == .pageNativeFileFacts {
                    value.jobs += 1
                    if value.jobs == 2 { value.armed = false }
                }
                guard point == .nativeFileDisplayProbe else { return false }
                value.probes += 1
                return value.probes == 1
            }
            if pause { barrier.pause() }
            return false
        })
        let items = try (0..<3).map { index in
            let url = fixture.root.appendingPathComponent("Selected \(index).txt")
            try Data("selected \(index)".utf8).write(to: url)
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects(items))
        guard case .captured(let capture) = try await fixture.sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("The multi-file fixture must be captured")
        }
        _ = try await fixture.sender.createTagDefinition(named: "Linked", assigningTo: capture.entryID)
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let before = try await fixture.receiver.page(.init())
        XCTAssertEqual(before.entries.first { $0.id == capture.entryID }?.syncFiles.count, 3)
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        observation.withLock { $0.armed = true }
        let cancelled = Task { try await fixture.receiver.page(.init()) }
        try await eventually { barrier.isWaiting }
        let successor = Task { try await fixture.receiver.page(.init(text: " ")) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("The cancelled page cannot return") }
        catch is CancellationError {}
        barrier.release()
        let next = try await successor.value
        XCTAssertEqual(next.entries.first { $0.id == capture.entryID }?.syncFiles.count, 3)
        XCTAssertEqual(observation.withLock { $0.probes }, 1,
            "Cancellation must stop the current entry's remaining native probes")
    }

    @MainActor
    func testCreatingTagCommitsBeforeNativeDisplayResolution() async throws {
        for deleteTag in [false, true] {
            let barrier = LinkedReplacementBarrier()
            defer { barrier.release() }
            let armed = OSAllocatedUnfairLock(initialState: false)
            let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
                if point == .entryNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
                return false
            })
            await fixture.sender.suspendSync()
            await fixture.receiver.suspendSync()
            let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("independent writer")))
            armed.withLock { $0 = true }
            let assignment = Task { try await fixture.receiver.createTagDefinition(named: "Committed tag", assigningTo: fixture.entryID) }
            try await eventually { barrier.isWaiting }
            let definitions = try await fixture.receiver.tagDefinitions()
            let tag = try XCTUnwrap(definitions.first { $0.displayName == "Committed tag" })
            let members = try await fixture.receiver.count(.init(tagID: tag.id))
            XCTAssertEqual(members, 1)
            _ = try await fixture.receiver.apply(.setFavorite(text.entryID, true))
            if deleteTag {
                _ = try await fixture.receiver.deleteTagDefinition(id: tag.id)
            } else {
                _ = try await fixture.receiver.renameTagDefinition(id: tag.id, to: "Latest tag name")
            }
            armed.withLock { $0 = false }
            barrier.release()
            if deleteTag {
                do { _ = try await assignment.value; XCTFail("A delayed reply cannot restore a deleted tag") }
                catch ClipboardHistoryModuleError.tagDefinitionNotFound {}
            } else {
                let result = try await assignment.value
                XCTAssertEqual(result.definition.id, tag.id)
                XCTAssertEqual(result.definition.displayName, "Latest tag name")
                XCTAssertTrue(result.entry.tagIDs.contains(tag.id))
                XCTAssertEqual(result.entry.syncFiles.first?.state, .complete)
            }
        }
    }

    @MainActor
    func testPageNativeWorkIsSerialCoalescedAndQueuedCancellationDoesNotInspect() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let waiting = NativeDisplayWaitController()
        let observation = OSAllocatedUnfairLock(initialState: (armed: false, calls: 0, outsideTask: true))
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: waiting.policy) { point in
            guard point == .pageNativeFileFacts else { return false }
            let first = observation.withLock { value in
                guard value.armed else { return false }
                value.calls += 1
                value.outsideTask = value.outsideTask && withUnsafeCurrentTask { $0 == nil }
                return value.calls == 1
            }
            if first { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        observation.withLock { $0.armed = true }
        waiting.arm()
        let first = Task { try await fixture.receiver.page(.init()) }
        try await eventually { barrier.isWaiting }
        let duplicate = Task { try await fixture.receiver.page(.init()) }
        let cancelled = Task { try await fixture.receiver.page(.init(text: "  ")) }
        // Distinct valid requests must queue, rather than fail at an arbitrary
        // admission limit. Whitespace queries all browse the same real file.
        let requests = (3...24).map { count in
            Task { try await fixture.receiver.page(.init(text: String(repeating: " ", count: count))) }
        }
        try await eventually { waiting.admissions == 25 }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("The cancelled request must not inspect a queued file")
        } catch is CancellationError {}
        XCTAssertEqual(waiting.pendingTimeouts, 24, "Cancellation must retire its own timeout")
        XCTAssertEqual(observation.withLock { $0.calls }, 1)
        XCTAssertTrue(observation.withLock { $0.outsideTask }, "Native work must not execute in a Swift task")
        let status = await fixture.receiver.status()
        XCTAssertEqual(status.availability, .ready)
        barrier.release()
        let initial = try await first.value
        let shared = try await duplicate.value
        XCTAssertEqual(initial, shared)
        for request in requests {
            let page = try await request.value
            XCTAssertTrue(page.entries.contains { $0.id == fixture.entryID })
        }
        XCTAssertEqual(observation.withLock { $0.calls }, 23)
        XCTAssertEqual(waiting.pendingTimeouts, 0, "Completed work must retire every waiter timer")
    }

    @MainActor
    func testTextOnlyPageDoesNotWaitForBlockedNativeDisplayWork() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let observation = OSAllocatedUnfairLock(initialState: (armed: false, calls: 0))
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
            guard point == .pageNativeFileFacts else { return false }
            let first = observation.withLock { value in
                guard value.armed else { return false }
                value.calls += 1
                return value.calls == 1
            }
            if first { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("independent text")))
        observation.withLock { $0.armed = true }
        let files = Task { try await fixture.receiver.page(.init(facet: .file)) }
        try await eventually { barrier.isWaiting }
        let page = try await fixture.receiver.page(.init(facet: .text))
        XCTAssertTrue(page.entries.contains { $0.id == text.entryID })
        XCTAssertTrue(page.entries.allSatisfy { $0.syncFiles.isEmpty && $0.linkedFileLocations.isEmpty })
        XCTAssertEqual(observation.withLock { $0.calls }, 1)
        barrier.release()
        _ = try await files.value
    }

    @MainActor
    func testMetadataMutationCommitsBeforeDisplayAndCancellationDoesNotRollItBack() async throws {
        for favorite in [true, false] {
            let barrier = LinkedReplacementBarrier()
            defer { barrier.release() }
            let armed = OSAllocatedUnfairLock(initialState: false)
            let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
                if point == .entryNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
                return false
            })
            await fixture.sender.suspendSync()
            await fixture.receiver.suspendSync()
            let tag = try await fixture.receiver.createTagDefinition(named: "Local metadata", assigningTo: fixture.entryID)
            _ = try await fixture.receiver.apply(.setTags(fixture.entryID, []))
            let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("writer remains usable")))
            armed.withLock { $0 = true }
            let request = Task {
                try await fixture.receiver.apply(favorite ? .setFavorite(fixture.entryID, true)
                    : .setTags(fixture.entryID, [tag.definition.id]))
            }
            try await eventually { barrier.isWaiting }
            let query = favorite ? ClipboardHistoryQuery(favoritesOnly: true) : ClipboardHistoryQuery(tagID: tag.definition.id)
            let committed = try await fixture.receiver.count(query)
            XCTAssertEqual(committed, 1)
            _ = try await fixture.receiver.apply(.setFavorite(text.entryID, true))
            let read = try await fixture.receiver.page(.init(facet: .text))
            XCTAssertEqual(read.entries.first { $0.id == text.entryID }?.isFavorite, true)
            request.cancel()
            do { _ = try await request.value; XCTFail("Cancelled display delivery must be discarded") }
            catch is CancellationError {}
            let retained = try await fixture.receiver.count(query)
            XCTAssertEqual(retained, favorite ? 2 : 1)
            armed.withLock { $0 = false }
            barrier.release()
        }
    }

    @MainActor
    func testMutationDisplayDoesNotRestoreAnEntryDeletedWhileNativeWorkWaits() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
            if point == .entryNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        armed.withLock { $0 = true }
        let request = Task { try await fixture.receiver.apply(.setFavorite(fixture.entryID, true)) }
        try await eventually { barrier.isWaiting }
        _ = try await fixture.receiver.apply(.delete(fixture.entryID))
        armed.withLock { $0 = false }
        barrier.release()
        let outcome = try await request.value
        XCTAssertEqual(outcome, .notFound)
    }

    @MainActor
    func testMutationDisplayUsesLatestMetadataWithoutFailingForOtherWrites() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init(nativeDisplayWaiting: .untimedForTests) { point in
            if point == .entryNativeFileFacts, armed.withLock({ $0 }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        armed.withLock { $0 = true }
        let first = Task { try await fixture.receiver.apply(.setFavorite(fixture.entryID, true)) }
        try await eventually { barrier.isWaiting }
        let second = Task { try await fixture.receiver.apply(.setFavorite(fixture.entryID, false)) }
        try await eventually { try await fixture.receiver.count(.init(favoritesOnly: true)) == 0 }
        for index in 0..<4 {
            _ = try await fixture.receiver.capture(.init(source: .unknown, content: .text("unrelated capture \(index)")))
        }
        armed.withLock { $0 = false }
        barrier.release()
        let oldRequest = try await first.value
        let newRequest = try await second.value
        guard case .updated(let firstEntry) = oldRequest, case .updated(let secondEntry) = newRequest else {
            return XCTFail("Both metadata mutations committed successfully")
        }
        XCTAssertFalse(firstEntry.isFavorite, "A delayed reply cannot restore the superseded favorite")
        XCTAssertFalse(secondEntry.isFavorite)
        XCTAssertEqual(firstEntry.syncFiles.first?.state, .complete)
        XCTAssertEqual(secondEntry.syncFiles.first?.state, .complete)
    }

    @MainActor
    func testMalformedLocalFileDescriptorDoesNotHideHealthyHistory() async throws {
        let fixture = try await makeLinkedFixture()
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("healthy local history")))
        let before = try await fixture.receiver.page(.init())
        let summary = try XCTUnwrap(before.entries.first { $0.id == fixture.entryID }?.syncFiles.first)
        try await fixture.receiver.closeStoreForTesting()
        let database = try ClipboardHistoryModule.openDatabase(
            at: ClipboardHistoryModule.databaseURL(in: fixture.receiverRoot),
            databaseKey: ClipboardHistoryKeyDerivation.deriveV1(from: Data(repeating: 0x52, count: 32)).databaseKey)
        defer { try? database.close() }
        // Deliberately damage only the closed, owned fixture. Connection
        // preparation also runs for read-only readers and cannot write here.
        try await database.write { database in
            try database.execute(sql: "UPDATE clipboard_sync_file_versions SET descriptor = ? WHERE object_id = ?",
                arguments: [Data("{".utf8), summary.id.uuidString])
        }
        try database.close()
        let reopened = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: fixture.receiverRoot,
            keyStore: NativeDisplayTestKey(), syncServices: fixture.services))
        let page = try await reopened.page(.init())
        XCTAssertTrue(page.entries.contains { $0.id == text.entryID })
        let damaged = try XCTUnwrap(page.entries.first { $0.id == fixture.entryID }?.syncFiles.first)
        XCTAssertEqual(damaged.id, summary.id)
        XCTAssertEqual(damaged.state, .localUnavailable)
        XCTAssertEqual(damaged.transferFailure, .corruptData)
        do {
            _ = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
            XCTFail("Display recovery cannot authorize malformed file metadata")
        } catch {}
        let healthy = try await reopened.materialize(.init(entryID: text.entryID, purpose: .normalPaste))
        XCTAssertFalse(healthy.items.isEmpty)
    }
}

private struct NativeDisplayTestKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x52, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}

extension ClipboardHistoryNativeDisplayWaiting {
    /// Barrier tests own completion explicitly; slow CI must not turn their
    /// deliberate pause into a production timeout. Deadline tests use the
    /// manual controller below instead.
    static let untimedForTests = ClipboardHistoryNativeDisplayWaiting(scheduleTimeout: { _ in {} }, didAdmit: {})
}

private final class NativeDisplayWaitController: Sendable {
    private struct State {
        var armed = false
        var admissions = 0
        var timeouts: [UUID: @Sendable () -> Void] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var admissions: Int { state.withLock { $0.admissions } }
    var pendingTimeouts: Int { state.withLock { $0.timeouts.count } }
    func arm() { state.withLock { $0.armed = true } }
    func expireAll() {
        let callbacks = state.withLock { Array($0.timeouts.values) }
        for callback in callbacks { callback() }
    }
    var policy: ClipboardHistoryNativeDisplayWaiting {
        .init(scheduleTimeout: { [self] callback in
            let id = UUID()
            let controlled = state.withLock { value in
                guard value.armed else { return false }
                value.timeouts[id] = callback
                return true
            }
            guard controlled else { return ClipboardHistoryNativeDisplayWaiting.live.scheduleTimeout(callback) }
            return { [self] in _ = state.withLock { $0.timeouts.removeValue(forKey: id) } }
        }, didAdmit: { [self] in state.withLock { if $0.armed { $0.admissions += 1 } } })
    }
}
