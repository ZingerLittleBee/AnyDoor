import XCTest

@testable import AnyDoor

final class HostsEditorViewTests: XCTestCase {
    func testDuplicateProfileActionLivesInEditorNotMenuBarPopover() throws {
        let editor = try source("Sources/AnyDoor/Views/Hosts/HostsEditorView.swift")
        XCTAssertTrue(editor.contains("duplicate(profile)"), editor)
        XCTAssertTrue(editor.contains("Label(L(.hostsProfileDuplicate)"), editor)

        let popover = try source("Sources/AnyDoor/Views/Hosts/HostsManagerPopoverView.swift")
        XCTAssertFalse(popover.contains("duplicateProfile"), popover)
        XCTAssertFalse(popover.contains("hostsProfileDuplicate"), popover)
    }

    func testProfileRowsDoNotInstallDoubleTapGestureThatCompetesWithSelection() throws {
        let editor = try source("Sources/AnyDoor/Views/Hosts/HostsEditorView.swift")

        XCTAssertFalse(editor.contains(".onTapGesture(count: 2)"), editor)
        XCTAssertTrue(editor.contains(".contentShape(Rectangle())"), editor)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
