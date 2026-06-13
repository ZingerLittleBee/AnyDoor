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

    func testProfileContextMenuOffersActivationToggle() throws {
        let editor = try source("Sources/AnyDoor/Views/Hosts/HostsEditorView.swift")

        XCTAssertTrue(editor.contains("toggleActive(profile)"), editor)
        XCTAssertTrue(editor.contains(".hostsProfileEnable"), editor)
        XCTAssertTrue(editor.contains(".hostsProfileDisable"), editor)
    }

    func testProfileActivationToggleIsFirstContextMenuItemAndDisableIsDestructive() throws {
        let editor = try source("Sources/AnyDoor/Views/Hosts/HostsEditorView.swift")
        let contextStart = try XCTUnwrap(editor.range(of: ".contextMenu {"))
        let context = editor[contextStart.lowerBound...]

        XCTAssertLessThan(
            try XCTUnwrap(context.range(of: "profileActivationMenuItem(profile)")?.lowerBound),
            try XCTUnwrap(context.range(of: "beginRename(profile)")?.lowerBound)
        )
        XCTAssertTrue(editor.contains("Button(role: .destructive) { toggleActive(profile) }"), editor)
    }

    func testActivationShowsLoadingInProfileRowAndUsesSharedTogglePath() throws {
        let editor = try source("Sources/AnyDoor/Views/Hosts/HostsEditorView.swift")

        XCTAssertTrue(editor.contains("@State private var applyingProfileIDs: Set<UUID> = []"), editor)
        XCTAssertTrue(editor.contains("ProgressView()"), editor)
        XCTAssertTrue(editor.contains("applyingProfileIDs.contains(profile.id)"), editor)
        XCTAssertTrue(editor.contains("private func toggleActive(_ profile: HostProfile)"), editor)
        XCTAssertEqual(editor.components(separatedBy: "manager.setActive").count - 1, 1, editor)
    }

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
