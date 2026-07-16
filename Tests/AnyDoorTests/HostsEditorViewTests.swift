import XCTest

@testable import AnyDoor

final class HostsEditorViewTests: XCTestCase {
    func testDuplicateProfileActionLivesInEditorNotMenuBarPopover() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")
        XCTAssertTrue(editor.contains("duplicate(profile)"), editor)
        XCTAssertTrue(editor.contains("LocalizedText(.hostsProfileDuplicate)"), editor)

        let popover = try source("Sources/HostsPlugin/Views/HostsManagerPopoverView.swift")
        XCTAssertFalse(popover.contains("duplicateProfile"), popover)
        XCTAssertFalse(popover.contains("hostsProfileDuplicate"), popover)
    }

    func testProfileRowsDoNotInstallDoubleTapGestureThatCompetesWithSelection() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")

        XCTAssertFalse(editor.contains(".onTapGesture(count: 2)"), editor)
        XCTAssertTrue(editor.contains(".contentShape(Rectangle())"), editor)
    }

    func testProfileContextMenuOffersActivationToggle() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")

        XCTAssertTrue(editor.contains("toggleActive(profile)"), editor)
        XCTAssertTrue(editor.contains(".hostsProfileEnable"), editor)
        XCTAssertTrue(editor.contains(".hostsProfileDisable"), editor)
    }

    func testProfileActivationToggleIsFirstContextMenuItemAndDisableIsDestructive() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")
        let contextStart = try XCTUnwrap(editor.range(of: ".contextMenu {"))
        let context = editor[contextStart.lowerBound...]

        XCTAssertLessThan(
            try XCTUnwrap(context.range(of: "profileActivationMenuItem(profile)")?.lowerBound),
            try XCTUnwrap(context.range(of: "beginRename(profile)")?.lowerBound)
        )
        XCTAssertTrue(editor.contains("Button(role: .destructive) { toggleActive(profile) }"), editor)
    }

    func testHostsEditorTitlebarToolbarDoesNotOverflowDeleteAction() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")
        let toolbarStart = try XCTUnwrap(editor.range(of: ".toolbar {")?.lowerBound)
        let detailStart = try XCTUnwrap(editor.range(of: "} detail: {")?.lowerBound)
        let toolbar = editor[toolbarStart..<detailStart]

        XCTAssertTrue(toolbar.contains("addProfile()"), editor)
        XCTAssertFalse(toolbar.contains("deleteSelected()"), editor)
        XCTAssertFalse(toolbar.contains("Image(systemName: \"trash\")"), editor)
        XCTAssertTrue(editor.contains(".onDeleteCommand { deleteSelected() }"), editor)
    }

    func testEditModeOffersCancelBesideSaveAndRestoresDraft() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")
        let modeButtonStart = try XCTUnwrap(editor.range(of: "private func modeButton")?.lowerBound)
        let selectedProfileStart = try XCTUnwrap(editor.range(of: "private var selectedProfile")?.lowerBound)
        let modeButton = editor[modeButtonStart..<selectedProfileStart]

        XCTAssertLessThan(
            try XCTUnwrap(modeButton.range(of: "Button(\"保存\")")?.lowerBound),
            try XCTUnwrap(modeButton.range(of: "Button(\"取消\", role: .cancel) { cancelEditing() }")?.lowerBound)
        )
        XCTAssertTrue(editor.contains("private func cancelEditing()"), editor)
        XCTAssertTrue(editor.contains("loadDraft()"), editor)
        XCTAssertTrue(editor.contains("mode = .view"), editor)
    }

    func testActivationShowsLoadingInProfileRowAndUsesSharedTogglePath() throws {
        let editor = try source("Sources/HostsPlugin/Views/HostsEditorView.swift")

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
