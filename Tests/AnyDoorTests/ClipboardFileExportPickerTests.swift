import AppKit
import ClipboardHistoryTestSupport
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardFileExportPickerTests: XCTestCase {
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
