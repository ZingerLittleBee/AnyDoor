import Darwin
import Foundation
import XCTest
import os

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testWorkingOutputRemovalCheckpointSurvivesProcessExitAndCompletesDownload() async throws {
        if let child = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await exitDuringWorkingOutputRemoval(at: URL(fileURLWithPath: child), afterCheckpoint: true)
            return XCTFail("Expected process exit after the durable removal checkpoint")
        }
        let fixture = try await interruptedWorkingOutputForRecovery(stage: "checkpoint")
        let exit = try await WorkingOutputCrash.run(root: fixture.root, bundle: Bundle(for: Self.self).bundleURL,
            test: "ClipboardHistoryLinkedFileTests/testWorkingOutputRemovalCheckpointSurvivesProcessExitAndCompletesDownload")
        XCTAssertEqual(exit.status, 76, exit.output)
        guard exit.status == 76 else { return }
        try assertFirstWorkingOutputMemberRemoved(fixture.pending)
        let reopened = makeLinkedModule(root: fixture.root.appendingPathComponent("Receiver"), services: fixture.services, key: 0x52)
        try await eventually { !FileManager.default.fileExists(atPath: fixture.pending.path) }
        try await assertRecoveredWorkingOutputDownload(reopened, root: fixture.root)
    }

    @MainActor
    func testWorkingOutputRemovalCheckpointRetriesAfterFaultOrCancellation() async throws {
        for cancellation in [false, true] {
            let fixture = try await interruptedWorkingOutputForRecovery(stage: "checkpoint")
            let reached = OSAllocatedUnfairLock(initialState: 0)
            let root = fixture.root.appendingPathComponent("Receiver")
            let module = makeLinkedModule(root: root, services: fixture.services, key: 0x52, faultInjector: .init { point in
                guard point == .workingOutputRemovalAfterCheckpoint else { return false }
                reached.withLock { $0 += 1 }
                if cancellation {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return false
                }
                return true
            })
            try await module.setSyncEnabled(true)
            await module.suspendSync()
            XCTAssertEqual(reached.withLock { $0 }, 1, "Stop after one durable member deletion")
            try assertFirstWorkingOutputMemberRemoved(fixture.pending)
            try await module.closeStoreForTesting()
            let reopened = makeLinkedModule(root: root, services: fixture.services, key: 0x52)
            try await eventually { !FileManager.default.fileExists(atPath: fixture.pending.path) }
            try await assertRecoveredWorkingOutputDownload(reopened, root: fixture.root)
        }
    }

    @MainActor
    func testWorkingOutputRemovalCheckpointPreservesChangedRemainderUntilKeep() async throws {
        if let child = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await exitDuringWorkingOutputRemoval(at: URL(fileURLWithPath: child), afterCheckpoint: true)
            return XCTFail("Expected process exit after the durable removal checkpoint")
        }
        for change in ["bytes", "directory-time", "extra", "identity"] {
            let fixture = try await interruptedWorkingOutputForRecovery(stage: "checkpoint")
            let exit = try await WorkingOutputCrash.run(root: fixture.root, bundle: Bundle(for: Self.self).bundleURL,
                test: "ClipboardHistoryLinkedFileTests/testWorkingOutputRemovalCheckpointPreservesChangedRemainderUntilKeep")
            XCTAssertEqual(exit.status, 76, exit.output)
            guard exit.status == 76 else { continue }
            try assertFirstWorkingOutputMemberRemoved(fixture.pending)
            let remaining = fixture.pending.appendingPathComponent("aaa.txt")
            let extra = fixture.pending.appendingPathComponent("user-added.txt")
            let bytes = Data("user-owned remainder".utf8)
            switch change {
            case "bytes": try bytes.write(to: remaining)
            case "directory-time":
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: fixture.pending.path)
            case "extra": try bytes.write(to: extra)
            default:
                let identical = try Data(contentsOf: remaining)
                try identical.write(to: remaining, options: .atomic)
            }
            let retainedBytes = try Data(contentsOf: remaining)
            let retainedDate = try FileManager.default.attributesOfItem(atPath: fixture.pending.path)[.modificationDate] as? Date
            let module = makeLinkedModule(root: fixture.root.appendingPathComponent("Receiver"), services: fixture.services, key: 0x52)
            try await eventually { try await module.workingOutputRecoveries().first?.reason == .changed }
            let notices = try await module.workingOutputRecoveries()
            let notice = try XCTUnwrap(notices.first, change)
            XCTAssertEqual(notices.count, 1, change)
            XCTAssertEqual(notice.reason, .changed, change)
            try await module.setSyncEnabled(true)
            await module.retrySync()
            XCTAssertEqual(try Data(contentsOf: remaining), retainedBytes, change)
            if change == "extra" { XCTAssertEqual(try Data(contentsOf: extra), bytes) }
            if change == "directory-time" {
                XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.pending.path)[.modificationDate] as? Date, retainedDate)
            }
            let repeated = try await module.workingOutputRecoveries()
            XCTAssertEqual(repeated.map(\.id), [notice.id], change)
            try await module.keepWorkingOutput(notice.id)
            try await assertRecoveredWorkingOutputDownload(module, root: fixture.root)
            XCTAssertEqual(try Data(contentsOf: remaining), retainedBytes, change)
            if change == "extra" { XCTAssertEqual(try Data(contentsOf: extra), bytes) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.pending.appendingPathComponent("member.txt").path),
                "Keep must not fill or replace the user's retained partial tree")
        }
    }

    @MainActor
    func testWorkingOutputUncheckpointedUnlinkRemainsForReview() async throws {
        if let child = ProcessInfo.processInfo.environment[WorkingOutputCrash.rootKey] {
            try await exitDuringWorkingOutputRemoval(at: URL(fileURLWithPath: child), afterCheckpoint: false)
            return XCTFail("Expected process exit between unlink and its checkpoint")
        }
        let fixture = try await interruptedWorkingOutputForRecovery(stage: "checkpoint")
        let exit = try await WorkingOutputCrash.run(root: fixture.root, bundle: Bundle(for: Self.self).bundleURL,
            test: "ClipboardHistoryLinkedFileTests/testWorkingOutputUncheckpointedUnlinkRemainsForReview")
        XCTAssertEqual(exit.status, 77, exit.output)
        guard exit.status == 77 else { return }
        try assertFirstWorkingOutputMemberRemoved(fixture.pending)
        let remaining = fixture.pending.appendingPathComponent("aaa.txt")
        let bytes = try Data(contentsOf: remaining)
        let module = makeLinkedModule(root: fixture.root.appendingPathComponent("Receiver"), services: fixture.services, key: 0x52)
        try await eventually { try await module.workingOutputRecoveries().first?.reason == .changed }
        let notices = try await module.workingOutputRecoveries()
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notice.reason, .changed)
        try await module.setSyncEnabled(true)
        await module.retrySync()
        XCTAssertEqual(try Data(contentsOf: remaining), bytes)
        let retained = try await module.workingOutputRecoveries()
        XCTAssertEqual(retained.map(\.id), [notice.id])
        try await module.keepWorkingOutput(notice.id)
        XCTAssertEqual(try Data(contentsOf: remaining), bytes)
    }

    @MainActor
    private func exitDuringWorkingOutputRemoval(at root: URL, afterCheckpoint: Bool) async throws {
        let services = try await restoreWorkingOutputServices(in: root)
        let target: ClipboardHistoryFaultPoint = afterCheckpoint ? .workingOutputRemovalAfterCheckpoint : .workingOutputRemovalAfterUnlink
        let module = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x52,
            faultInjector: .init { point in
                if point == target { _exit(afterCheckpoint ? 76 : 77) }
                return false
            })
        try await module.setSyncEnabled(true)
        await module.retrySync()
    }

    private func assertFirstWorkingOutputMemberRemoved(_ pending: URL) throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.appendingPathComponent("member.txt").path))
        XCTAssertEqual(try Data(contentsOf: pending.appendingPathComponent("aaa.txt")), Data("completed member".utf8))
    }

    @MainActor
    private func assertRecoveredWorkingOutputDownload(_ module: ClipboardHistoryModule, root: URL) async throws {
        try await module.setSyncEnabled(true)
        await module.retrySync()
        let notices = try await module.workingOutputRecoveries()
        XCTAssertTrue(notices.isEmpty)
        let entries = try await module.page(.init()).entries
        let entry = try XCTUnwrap(entries.first)
        let materialized = try await module.materialize(.init(entryID: entry.id, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else {
            return XCTFail("Expected a complete downloaded tree after recovery")
        }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("member.txt")),
            try Data(contentsOf: root.appendingPathComponent("Notes/member.txt")))
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("aaa.txt")), Data("completed member".utf8))
    }
}
