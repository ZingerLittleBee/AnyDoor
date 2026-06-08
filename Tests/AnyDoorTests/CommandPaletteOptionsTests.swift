import XCTest
@testable import AnyDoor

final class CommandPaletteOptionsTests: XCTestCase {
    @MainActor
    func testPaletteOptionSourceMakesStableID() {
        let source = PanelEntry.Source.paletteOption(id: "keepAwake.15")
        XCTAssertEqual(PanelEntry.id(for: source), "option:keepAwake.15")
    }

    @MainActor
    func testPaletteOptionLocalizedTitleReturnsStoredTitle() {
        let entry = PanelEntry(
            id: "option:x",
            source: .paletteOption(id: "x"),
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: "30 minutes",
            subtitle: nil,
            symbol: "clock",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
        XCTAssertEqual(entry.localizedTitle(), "30 minutes")
    }

    @MainActor
    func testKeepAwakeOptionsOffHasNoTurnOff() {
        let options = CommandPaletteOptions.keepAwakeOptions(isOn: false)
        XCTAssertEqual(options.map(\.id),
                       ["keepAwake.indefinite", "keepAwake.15", "keepAwake.30",
                        "keepAwake.60", "keepAwake.120"])
        XCTAssertFalse(options.contains { $0.role == .destructive })
    }

    @MainActor
    func testKeepAwakeOptionsOnAppendsTurnOff() {
        let options = CommandPaletteOptions.keepAwakeOptions(isOn: true)
        XCTAssertEqual(options.last?.id, "keepAwake.off")
        XCTAssertEqual(options.last?.role, .destructive)
        XCTAssertEqual(options.count, 6)
    }

    @MainActor
    func testScheduledShutdownOptionsArmedAppendsCancel() {
        XCTAssertEqual(CommandPaletteOptions.scheduledShutdownOptions(isArmed: false).count, 4)
        let armed = CommandPaletteOptions.scheduledShutdownOptions(isArmed: true)
        XCTAssertEqual(armed.count, 5)
        XCTAssertEqual(armed.last?.id, "scheduledShutdown.cancel")
        XCTAssertEqual(armed.last?.role, .destructive)
    }

    @MainActor
    func testBrightnessOptionsNilWithoutDDCDisplay() {
        XCTAssertNil(CommandPaletteOptions.brightnessOptions(displays: []))
        let noDDC = [DisplayInfo(id: 1, name: "A", supportsDDC: false)]
        XCTAssertNil(CommandPaletteOptions.brightnessOptions(displays: noDDC))
    }

    @MainActor
    func testBrightnessOptionsLabelsAndIDs() throws {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let options = try XCTUnwrap(
            CommandPaletteOptions.brightnessOptions(
                displays: [DisplayInfo(id: 1, name: "A", supportsDDC: true)]
            )
        )
        XCTAssertEqual(options.map(\.id),
                       ["brightness.0", "brightness.25", "brightness.50",
                        "brightness.75", "brightness.100"])
        XCTAssertEqual(options.map(\.title),
                       ["0%", "25%", "50%", "75%", "100%"])
    }

    @MainActor
    func testHostsOptionsCheckmarkAndEditAlwaysPresent() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let active = HostProfile(name: "Dev", isActive: true)
        let inactive = HostProfile(name: "Prod", isActive: false)
        let options = CommandPaletteOptions.hostsOptions(profiles: [active, inactive])

        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options[0].title, "Dev")
        XCTAssertTrue(options[0].isChecked)
        XCTAssertEqual(options[1].title, "Prod")
        XCTAssertFalse(options[1].isChecked)
        XCTAssertEqual(options.last?.id, "hosts.edit")

        XCTAssertEqual(CommandPaletteOptions.hostsOptions(profiles: []).map(\.id),
                       ["hosts.edit"])
    }

    @MainActor
    func testIsOptionParent() {
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.keepAwake))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.scheduledShutdown))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.brightness))
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.hostsManager))
        XCTAssertFalse(CommandPaletteOptions.isOptionParent(.muteAudio))
        XCTAssertFalse(CommandPaletteOptions.isOptionParent(.windowLayout))
    }

    @MainActor
    private func sampleOptions() -> [CommandPaletteOption] {
        [
            CommandPaletteOption(id: "a", title: "Alpha", symbol: "clock", perform: {}),
            CommandPaletteOption(id: "b", title: "Beta", symbol: "clock", perform: {}),
        ]
    }

    @MainActor
    func testEnterOptionsSwitchesLevelAndResetsQuery() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 3

        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())

        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertEqual(state.flatEntries.map(\.id), ["option:a", "option:b"])
        XCTAssertTrue(state.filteredSections.isEmpty) // dynamic sections suppressed off-root
        XCTAssertEqual(state.option(id: "a")?.title, "Alpha")
    }

    @MainActor
    func testSecondLevelSearchFilters() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        state.query = "bet"
        XCTAssertEqual(state.flatEntries.map(\.id), ["option:b"])
    }

    @MainActor
    func testPopToRootRestoresRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        state.query = "x"
        state.selectedIndex = 1

        state.popToRoot()

        XCTAssertTrue(state.isAtRoot)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertNil(state.option(id: "a"))
    }
}
