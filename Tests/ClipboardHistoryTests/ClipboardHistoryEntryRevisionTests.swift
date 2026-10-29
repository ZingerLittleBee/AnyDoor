import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

final class ClipboardHistoryEntryRevisionTests: XCTestCase {
    func testMaterializationRevisionTracksExactTextAndPreservesMetadataOnlyChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("entry-revision-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root,
            keyStore: EntryRevisionLocalKey()))
        let prefix = String(repeating: "same visible prefix ", count: 300)
        let first = try await module.capture(.init(source: .unknown, content: .text(prefix + "first")))
        let other = try await module.capture(.init(source: .unknown, content: .text("unrelated")))
        let initial = try await module.page(.init())
        let original = try XCTUnwrap(initial.entries.first { $0.id == first.entryID })
        let unrelated = try XCTUnwrap(initial.entries.first { $0.id == other.entryID })
        XCTAssertNotEqual(original.materializationRevision, 0)
        _ = try await module.apply(.setFavorite(first.entryID, true))
        let tag = try await module.createTagDefinition(named: "Metadata", assigningTo: first.entryID)
        _ = try await module.renameTagDefinition(id: tag.definition.id, to: "Renamed metadata")
        let metadata = try await module.page(.init())
        XCTAssertEqual(metadata.entries.first { $0.id == first.entryID }?.materializationRevision,
            original.materializationRevision)
        let edit = try await module.apply(.editText(first.entryID, prefix + "second"))
        guard case .updated(let updated) = edit else { return XCTFail("Expected an updated text result") }
        XCTAssertEqual(updated.previewText, original.previewText, "The exact content changes beyond the card preview")
        XCTAssertNotEqual(updated.materializationRevision, original.materializationRevision)
        let fresh = try await module.page(.init())
        XCTAssertEqual(fresh.entries.first { $0.id == first.entryID }?.materializationRevision,
            updated.materializationRevision)
        XCTAssertEqual(fresh.entries.first { $0.id == other.entryID }?.materializationRevision,
            unrelated.materializationRevision)
        let materialized = try await module.materialize(.init(entryID: first.entryID, purpose: .normalPaste))
        XCTAssertTrue(materialized.items.flatMap(\.representations).contains { representation in
            guard case .text(_, let value) = representation else { return false }
            return value == prefix + "second"
        })
    }
}

private struct EntryRevisionLocalKey: ClipboardHistoryMasterKeyStoring {
    func load() -> ClipboardHistoryMasterKeyResult { .key(Data(repeating: 0x41, count: 32)) }
    func create() -> ClipboardHistoryMasterKeyResult { load() }
    func delete() -> ClipboardHistoryMasterKeyResult { .missing }
}
