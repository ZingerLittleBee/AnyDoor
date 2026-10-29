import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardLinkedLocationPresentationTests: XCTestCase {
    func testLinkedLocationActionsKeepTheLoadedDepthAndSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-location-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Notes.txt")
        try Data("linked contents".utf8).write(to: source)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Store"),
            keyStore: FileConflictUILocalKey(byte: 0x65),
            syncServices: .init(transport: FileConflictUICloud(), keys: FileConflictUIKeys(), pollingInterval: nil)))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.linked-location-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let captured) = try await module.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("The owned file must be captured")
        }
        let tag = try await module.createTagDefinition(named: "Shared", assigningTo: captured.entryID)
        try await module.setSyncTagSelected(tag.definition.id, selected: true)
        try await module.setSyncEnabled(true)
        for number in 0..<105 {
            _ = try await module.capture(.init(source: .unknown, content: .text("Newer entry \(number)")))
        }
        let model = ClipboardHistoryPresentationModel(module: module)
        await model.reload()
        await model.loadNextPage()
        model.select(captured.entryID)
        XCTAssertEqual(model.entries.count, 106)
        let initialLocations = try await module.linkedFileLocations(for: captured.entryID)
        let initial = try XCTUnwrap(initialLocations.first)
        let selection = ClipboardHistoryFileLocationSelection(entryID: captured.entryID,
            locationID: initial.id, expectedRevision: initial.revision)

        let paused = await model.setFileLocationPaused(selection, paused: true)

        XCTAssertTrue(paused)
        XCTAssertEqual(model.entries.count, 106)
        XCTAssertEqual(model.selectedID, captured.entryID)
        XCTAssertEqual(model.selectedEntry?.linkedFileLocations.first?.state, .paused)

        let stale = await model.setFileLocationPaused(selection, paused: false)
        XCTAssertFalse(stale)
        XCTAssertEqual(model.actionFailure, .operationUnavailable)
        XCTAssertEqual(model.entries.count, 106)
        XCTAssertEqual(model.selectedID, captured.entryID)

        let independent = root.appendingPathComponent("Independent.txt")
        _ = try await module.exportFiles(captured.entryID, to: [independent])
        let associated = await model.associateFileLocation(.init(entryID: captured.entryID,
            objectID: initial.objectID, url: independent))
        XCTAssertTrue(associated)
        XCTAssertEqual(model.entries.count, 106)
        XCTAssertEqual(model.selectedID, captured.entryID)
        let locations = try await module.linkedFileLocations(for: captured.entryID)
        let additional = try XCTUnwrap(locations.first { $0.url == independent })
        let replacement = root.appendingPathComponent("Replacement.txt")
        try Data("linked contents".utf8).write(to: replacement)
        let reassociated = await model.reassociateFileLocation(.init(selection: .init(entryID: captured.entryID,
            locationID: additional.id, expectedRevision: additional.revision), url: replacement))
        XCTAssertTrue(reassociated)
        XCTAssertEqual(model.entries.count, 106)
        XCTAssertEqual(model.selectedID, captured.entryID)
        XCTAssertTrue(model.selectedEntry?.linkedFileLocations.contains { $0.url == replacement } == true)
        XCTAssertEqual(model.pagingState, .complete)
        XCTAssertEqual(try Data(contentsOf: source), Data("linked contents".utf8))
    }
}
