import Foundation
import os
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testPageFileInspectionRejectsAReopenedStore() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .pageNativeFileFacts, armed.withLock({ value in
                let held = value
                value = false
                return held
            }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        armed.withLock { $0 = true }
        let page = Task { try await fixture.receiver.page(.init()) }
        let deadline = Date().addingTimeInterval(5)
        while !barrier.isWaiting, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(barrier.isWaiting)
        await fixture.receiver.retry()
        barrier.release()
        do {
            _ = try await page.value
            XCTFail("Reopening the pool must invalidate a page from its preceding lifetime")
        } catch ClipboardHistoryModuleError.storeUnavailable {}
        let current = try await fixture.receiver.page(.init())
        XCTAssertEqual(current.entries.map(\.id), [fixture.entryID])
    }

    @MainActor
    func testPageFileInspectionBoundsRetriesDuringRepeatedMutations() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let gate = OSAllocatedUnfairLock(initialState: (armed: false, passes: 0))
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .pageNativeFileFacts, gate.withLock({ state in
                guard state.armed else { return false }
                state.passes += 1
                return true
            }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        gate.withLock { $0.armed = true }
        let page = Task { try await fixture.receiver.page(.init()) }
        for pass in 1...3 {
            let deadline = Date().addingTimeInterval(5)
            while gate.withLock({ $0.passes }) < pass, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(gate.withLock { $0.passes }, pass)
            _ = try await fixture.receiver.apply(.setFavorite(fixture.entryID, pass.isMultiple(of: 2) == false))
            barrier.release()
        }
        do {
            _ = try await page.value
            XCTFail("A continuously changing page must return a bounded retry outcome")
        } catch ClipboardHistoryModuleError.operationUnavailable {}
        XCTAssertEqual(gate.withLock { $0.passes }, 3)
    }

    @MainActor
    func testPageFileInspectionReleasesWriterAndRejectsStaleSnapshot() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let armed = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .pageNativeFileFacts, armed.withLock({ value in
                let held = value
                value = false
                return held
            }) { barrier.pause() }
            return false
        })
        await fixture.sender.suspendSync()
        await fixture.receiver.suspendSync()
        let text = try await fixture.receiver.capture(.init(source: .unknown, content: .text("delete during native inspection")))
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        armed.withLock { $0 = true }
        let page = Task { try await fixture.receiver.page(.init()) }
        let reached = Date().addingTimeInterval(5)
        while !barrier.isWaiting, Date() < reached { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(barrier.isWaiting)
        try FileManager.default.removeItem(at: working.url)
        let completed = OSAllocatedUnfairLock(initialState: false)
        let mutation = Task {
            let outcome = try await fixture.receiver.apply(.delete(text.entryID))
            completed.withLock { $0 = true }
            return outcome
        }
        let deadline = Date().addingTimeInterval(2)
        while !completed.withLock({ $0 }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(completed.withLock { $0 }, "A native file check must not hold the module actor or database read")
        barrier.release()
        _ = try await mutation.value
        let result = try await page.value
        XCTAssertFalse(result.entries.contains { $0.id == text.entryID }, "A changed store revision must invalidate the pending page")
        XCTAssertEqual(result.entries.first { $0.id == fixture.entryID }?.syncFiles.first?.state, .localUnavailable)
        do {
            _ = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
            XCTFail("Display resolution must not authorize a disappeared file")
        } catch ClipboardHistoryModuleError.fileReferencesUnavailable {}
    }
}
