import Foundation
import os
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testRejoinBodyVerificationRespectsWithdrawalDeletionAndDisable() async throws {
        for action in ["withdraw", "delete", "disable"] {
            let barrier = LinkedReplacementBarrier()
            defer { barrier.release() }
            let armed = OSAllocatedUnfairLock(initialState: false)
            let fixture = try await makeLinkedFixture(receiverFault: .init { point in
                if point == .syncFileVerificationSegment, armed.withLock({ value in
                    guard value else { return false }
                    value = false
                    return true
                }) { barrier.pause() }
                return false
            }, prepareSource: { root in
                try FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("retained tree".utf8).write(to: root.appendingPathComponent("member"))
            })
            let tags = try await fixture.sender.tagDefinitions()
            let tag = try XCTUnwrap(tags.first)
            try await fixture.sender.setSyncTagSelected(tag.id, selected: false)
            await fixture.receiver.retrySync()
            try await fixture.sender.setSyncEnabled(false)
            armed.withLock { $0 = true }
            let rejoin = Task { try await fixture.receiver.setSyncTagSelected(tag.id, selected: true) }
            try await eventually { barrier.isWaiting }
            if action == "withdraw" {
                try await fixture.receiver.setSyncTagSelected(tag.id, selected: false, waitForSync: false)
            } else if action == "delete" {
                _ = try await fixture.receiver.apply(.delete(fixture.entryID))
            } else {
                let cancellations = await fixture.cloud.cancellationCount()
                let disabled = Task { try await fixture.receiver.setSyncEnabled(false) }
                try await eventually { await fixture.cloud.cancellationCount() > cancellations }
                barrier.release()
                try await disabled.value
            }
            barrier.release()
            try await rejoin.value
            await fixture.receiver.retrySync()
            let visible = await fixture.cloud.visibleRecords()
            XCTAssertTrue(visible.filter { $0.kind == .fileBody }.isEmpty, "Revoked \(action) cannot publish the verified body")
        }
    }

    @MainActor
    func testNewRejoinActivationAuthenticatesAgainAfterSuspendedVerification() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let observed = OSAllocatedUnfairLock(initialState: (armed: false, segments: 0))
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileVerificationSegment {
                let pause = observed.withLock { value in
                    value.segments += 1
                    let pause = value.armed
                    value.armed = false
                    return pause
                }
                if pause { barrier.pause() }
            }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("retained activation".utf8).write(to: root.appendingPathComponent("member"))
        })
        let tags = try await fixture.sender.tagDefinitions()
        let tag = try XCTUnwrap(tags.first)
        try await fixture.sender.setSyncTagSelected(tag.id, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)
        observed.withLock { $0 = (true, 0) }
        let rejoin = Task { try await fixture.receiver.setSyncTagSelected(tag.id, selected: true) }
        try await eventually { barrier.isWaiting }
        try await fixture.receiver.setSyncTagSelected(tag.id, selected: false, waitForSync: false)
        try await fixture.receiver.setSyncTagSelected(tag.id, selected: true, waitForSync: false)
        barrier.release()
        try await rejoin.value
        await fixture.receiver.retrySync()

        XCTAssertEqual(observed.withLock { $0.segments }, 2, "A changed activation cannot consume the old verification result")
        let visible = await fixture.cloud.visibleRecords()
        XCTAssertEqual(visible.filter { $0.kind == .fileBody }.count, 1)
    }

    @MainActor
    func testRestartRejectsPreviouslyPreparedRestorationWhoseCiphertextDisappeared() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .syncFileVerificationSegment, armed.withLock({ value in
                guard value else { return false }
                value = false
                return true
            }) { barrier.pause() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("original retained tree".utf8).write(to: root.appendingPathComponent("member"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let tags = try await fixture.sender.tagDefinitions()
        let tag = try XCTUnwrap(tags.first)
        try await fixture.sender.setSyncTagSelected(tag.id, selected: false)
        await fixture.receiver.retrySync()
        try await fixture.sender.setSyncEnabled(false)
        armed.withLock { $0 = true }
        let rejoin = Task { try await fixture.receiver.setSyncTagSelected(tag.id, selected: true) }
        try await eventually { barrier.isWaiting }
        // The ordinary checkpoint has already uploaded; only the verified body
        // commit now fails, leaving its real prepared location durable.
        await fixture.cloud.failCommits(true)
        barrier.release()
        try await rejoin.value
        let failed = await fixture.receiver.syncStatus()
        XCTAssertEqual(failed.phase, .failed(.network))
        try await fixture.receiver.closeStoreForTesting()
        try FileManager.default.removeItem(at: fixture.receiverRoot.appendingPathComponent("SyncTransfers/Downloads"))
        let edited = Data("saved after prepared ciphertext was lost".utf8)
        try edited.write(to: working.url.appendingPathComponent("member"))
        await fixture.cloud.failCommits(false)
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

        await reopened.resumeSync()

        let page = try await reopened.page(.init())
        let replacement = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertNotEqual(replacement.versionID, working.baseVersionID)
        let visible = await fixture.cloud.visibleRecords()
        XCTAssertFalse(visible.contains { $0.kind == .fileBody && $0.operationID == working.baseVersionID })
        let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh restarted restoration"),
            services: fixture.services, key: 0x53)
        try await fresh.setSyncEnabled(true)
        let restored = try await fresh.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(restored.first?.url).appendingPathComponent("member")), edited)
    }

    @MainActor
    func testRejoinAuthenticatesEachRetainedBodyOnceAsVersionHistoryGrows() async throws {
        for count in [3, 6] {
            let authentication = OSAllocatedUnfairLock(initialState: (armed: false, segments: 0))
            let fixture = try await makeLinkedFixture(receiverFault: .init { point in
                if point == .syncFileVerificationSegment {
                    authentication.withLock { if $0.armed { $0.segments += 1 } }
                }
                return false
            }, prepareSource: { root in
                try FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 64_000).write(to: root.appendingPathComponent("member"))
            })
            let originalLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            var versions = Set([try XCTUnwrap(originalLocations.first?.baseVersionID)])
            for index in 1..<count {
                try Data(repeating: UInt8(0x41 + index), count: 64_000)
                    .write(to: fixture.original.appendingPathComponent("member"))
                await fixture.sender.retrySync()
                await fixture.receiver.retrySync()
                let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
                versions.insert(try XCTUnwrap(locations.first?.baseVersionID))
            }
            XCTAssertEqual(versions.count, count)
            let before = await fixture.cloud.visibleRecords().filter { $0.kind == .fileBody }
            XCTAssertEqual(before.count, count)
            XCTAssertTrue(before.allSatisfy { $0.chunkCount == 1 }, "Each fixed-size tree must fit one authenticated segment")
            let tags = try await fixture.sender.tagDefinitions()
            let tag = try XCTUnwrap(tags.first)
            try await fixture.sender.setSyncTagSelected(tag.id, selected: false)
            await fixture.receiver.retrySync()
            try await fixture.sender.setSyncEnabled(false)
            authentication.withLock { $0.armed = true }

            try await fixture.receiver.setSyncTagSelected(tag.id, selected: true)

            let work = authentication.withLock { $0.segments }
            print("RESTORATION_VERIFIED_SEGMENTS versions=\(count) segments=\(work)")
            XCTAssertEqual(work, count, "Acknowledging one body must not authenticate every remaining body again")
            let restored = await fixture.cloud.visibleRecords().filter { $0.kind == .fileBody }
            XCTAssertEqual(Set(restored.map(\.operationID)), versions)
            let fresh = makeLinkedModule(root: fixture.root.appendingPathComponent("Fresh restoration"),
                services: fixture.services, key: 0x53)
            try await fresh.setSyncEnabled(true)
            let locations = try await fresh.linkedFileLocations(for: fixture.entryID)
            let current = try XCTUnwrap(locations.first)
            XCTAssertEqual(try Data(contentsOf: current.url.appendingPathComponent("member")),
                Data(repeating: UInt8(0x41 + count - 1), count: 64_000))
        }
    }
}
