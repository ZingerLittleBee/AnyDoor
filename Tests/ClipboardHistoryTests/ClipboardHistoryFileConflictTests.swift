import AppKit
import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testOfflineDivergenceExposesBothContentsAndSurvivesRestart() async throws {
        let fixture = try await makeLinkedFixture()
        let initial = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(initial.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let originalEdit = Data("offline original edit".utf8)
        let workingEdit = Data("offline working edit".utf8)
        try originalEdit.write(to: fixture.original)
        try workingEdit.write(to: working.url)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        let plan = try await fixture.receiver.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)

        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertTrue(plan.candidates.contains { $0.id == .localLocation(working.id) && $0.availability == .available })
        XCTAssertTrue(plan.candidates.contains { candidate in
            if case .version(let id) = candidate.id { return id != working.baseVersionID }
            return false
        })
        XCTAssertEqual(try Data(contentsOf: working.url), workingEdit)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalEdit)
        try await fixture.receiver.closeStoreForTesting()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)
        let restored = try await reopened.fileConflictPlan(entryID: fixture.entryID, objectID: working.objectID)
        XCTAssertEqual(restored.candidates.map(\.id), plan.candidates.map(\.id))
        XCTAssertEqual(try Data(contentsOf: working.url), workingEdit)
    }
}
