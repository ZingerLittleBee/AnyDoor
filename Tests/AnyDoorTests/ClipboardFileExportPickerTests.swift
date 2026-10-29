import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardFileExportPickerTests: XCTestCase {
    func testMultipleExportsAvoidExistingNamesAndRetainTheFinalCollisionGuard() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-many-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let first = root.appendingPathComponent("First/Notes.txt")
        let second = root.appendingPathComponent("Second/notes.txt")
        let directory = root.appendingPathComponent("Exports")
        for folder in [first.deletingLastPathComponent(), second.deletingLastPathComponent(), directory] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("first file".utf8).write(to: first)
        try Data("second file".utf8).write(to: second)
        let existing = directory.appendingPathComponent("Notes.txt")
        let suffixed = directory.appendingPathComponent("Notes 2.txt")
        try Data("existing file".utf8).write(to: existing)
        try Data("existing suffix".utf8).write(to: suffixed)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Store"),
            keyStore: FileConflictUILocalKey(byte: 0x67)))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.export-many.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([first as NSURL, second as NSURL]))
        guard case .captured(let capture) = try await module.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("Expected both owned files to be captured")
        }
        let presentation = ClipboardHistoryPresentationModel(module: module)
        let content = await presentation.materialization(for: capture.entryID, purpose: .hostAction, usesCache: false)
        let sources = try XCTUnwrap(content?.fileURLs)
        XCTAssertEqual(sources.count, 2)
        let picker = ClipboardFileExportPicker()
        let destinations = try picker.destinations(for: sources, in: directory)
        XCTAssertEqual(destinations.map(\.lastPathComponent), ["Notes 3.txt", "notes 4.txt"])

        let exported = await presentation.exportFiles(capture.entryID, to: destinations)
        XCTAssertTrue(exported)
        guard exported else { return }
        XCTAssertEqual(try Data(contentsOf: destinations[0]), Data("first file".utf8))
        XCTAssertEqual(try Data(contentsOf: destinations[1]), Data("second file".utf8))
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing file".utf8))
        XCTAssertEqual(try Data(contentsOf: suffixed), Data("existing suffix".utf8))

        let raced = try picker.destinations(for: sources, in: directory)
        try Data("created after choosing the folder".utf8).write(to: raced[1])
        let collision = await presentation.exportFiles(capture.entryID, to: raced)
        XCTAssertFalse(collision)
        XCTAssertEqual(presentation.actionFailure, .fileExportCollision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: raced[0].path))
        XCTAssertEqual(try Data(contentsOf: raced[1]), Data("created after choosing the folder".utf8))
    }

    func testOccupiedDestinationIsRefusedBeforeIndependentExport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("export-picker-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.txt")
        let existing = root.appendingPathComponent("Existing.txt")
        let available = root.appendingPathComponent("New name.txt")
        try Data("exported content".utf8).write(to: source)
        try Data("existing independent edit".utf8).write(to: existing)
        let picker = ClipboardFileExportPicker()

        XCTAssertThrowsError(try picker.validateDestination(existing))

        XCTAssertEqual(try Data(contentsOf: existing), Data("existing independent edit".utf8))
        try picker.validateDestination(available)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Store"),
            keyStore: FileConflictUILocalKey(byte: 0x66)))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.export-picker.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(source.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await module.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            return XCTFail("The owned source must be captured")
        }
        let presentation = ClipboardHistoryPresentationModel(module: module)
        let exported = await presentation.exportFiles(capture.entryID, to: [available])
        XCTAssertTrue(exported)
        XCTAssertEqual(try Data(contentsOf: available), Data("exported content".utf8))
        let locations = try await module.linkedFileLocations(for: capture.entryID)
        XCTAssertTrue(locations.isEmpty)
        let collided = await presentation.exportFiles(capture.entryID, to: [existing])
        XCTAssertFalse(collided, "The module must retain its final race guard")
        XCTAssertEqual(presentation.actionFailure, .fileExportCollision)
        XCTAssertEqual(try Data(contentsOf: existing), Data("existing independent edit".utf8))
    }
}
