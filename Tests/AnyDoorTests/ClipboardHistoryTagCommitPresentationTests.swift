import AppKit
import Foundation
import os
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryTagCommitPresentationTests: XCTestCase {
    func testCommittedDefinitionAppearsWhenItsEntryIsDeletedBeforeTheReply() async throws {
        let barrier = TagDisplayBarrier()
        defer { barrier.release() }
        let fixture = try await makeFixture(barrier: barrier)
        let model = ClipboardHistoryPresentationModel(module: fixture.module)
        await model.reload()
        barrier.arm()
        let creation = Task { await model.createTagDefinition(named: "Retained definition", assigningTo: fixture.fileID) }
        try await waitForDisplay(barrier)
        let committed = try await fixture.module.tagDefinitions()
        let tag = try XCTUnwrap(committed.first { $0.displayName == "Retained definition" })
        _ = try await fixture.module.apply(.delete(fixture.fileID))
        // The wall's mutation subscriber refreshes entries, without replacing
        // its current tag definitions or loaded history depth.
        await model.refreshForStoreChange()
        XCTAssertEqual(model.entries.map(\.id), [fixture.textID])
        XCTAssertFalse(model.tags.contains { $0.id == tag.id })

        barrier.release()
        let accepted = await creation.value

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.actionFailure, .entryNotFound)
        XCTAssertTrue(model.tags.contains { $0 == tag })
        XCTAssertEqual(model.entries.map(\.id), [fixture.textID], "The delayed reply cannot restore the deleted entry")
        let memberships = try await fixture.module.count(.init(tagID: tag.id))
        XCTAssertEqual(memberships, 0)
    }

    func testDeletedDefinitionIsNotRestoredByACommittedAssignmentReply() async throws {
        let barrier = TagDisplayBarrier()
        defer { barrier.release() }
        let fixture = try await makeFixture(barrier: barrier)
        let tag = try await fixture.module.createTagDefinition(named: "Removed definition", assigningTo: fixture.textID).definition
        let model = ClipboardHistoryPresentationModel(module: fixture.module)
        await model.reload()
        XCTAssertTrue(model.tags.contains { $0.id == tag.id })
        barrier.arm()
        let creation = Task { await model.createTagDefinition(named: tag.displayName, assigningTo: fixture.fileID) }
        try await waitForDisplay(barrier)
        _ = try await fixture.module.deleteTagDefinition(id: tag.id)

        barrier.release()
        let accepted = await creation.value

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.actionFailure, .invalidTagDefinition)
        XCTAssertFalse(model.tags.contains { $0.id == tag.id })
        await model.refreshForStoreChange()
        XCTAssertEqual(Set(model.entries.map(\.id)), [fixture.fileID, fixture.textID])
        XCTAssertFalse(model.entries.contains { $0.tagIDs.contains(tag.id) })
        let definitions = try await fixture.module.tagDefinitions()
        XCTAssertFalse(definitions.contains { $0.id == tag.id })
    }

    private func makeFixture(barrier: TagDisplayBarrier) async throws -> (
        module: ClipboardHistoryModule, fileID: ClipboardHistoryEntryID, textID: ClipboardHistoryEntryID
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tag-commit-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Notes.txt")
        try Data("file requiring native display facts".utf8).write(to: source)
        let services = ClipboardSyncServices(transport: FileConflictUICloud(), keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x71), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x72), faultInjector: .init(
                nativeDisplayWaiting: .init(scheduleTimeout: { _ in {} }, didAdmit: {})
            ) { point in
                if point == .entryNativeFileFacts { barrier.pauseIfArmed() }
                return false
            }, syncServices: services))
        addTeardownBlock { barrier.release() }
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.tag-commit-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let shared = try await sender.createTagDefinition(named: "Shared", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(shared.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        await sender.suspendSync()
        await receiver.suspendSync()
        let text = try await receiver.capture(.init(source: .unknown, content: .text("independent surviving entry")))
        return (receiver, capture.entryID, text.entryID)
    }

    private func waitForDisplay(_ barrier: TagDisplayBarrier) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !barrier.isWaiting, Date() < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(barrier.isWaiting, "The tag transaction must commit before the display reply is released")
    }
}

private final class TagDisplayBarrier: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (armed: false, waiting: false))
    private let semaphore = DispatchSemaphore(value: 0)

    var isWaiting: Bool { state.withLock { $0.waiting } }
    func arm() { state.withLock { $0.armed = true } }
    func pauseIfArmed() {
        let shouldWait = state.withLock { value in
            guard value.armed else { return false }
            value.armed = false
            value.waiting = true
            return true
        }
        if shouldWait { semaphore.wait() }
    }
    func release() { semaphore.signal() }
}
