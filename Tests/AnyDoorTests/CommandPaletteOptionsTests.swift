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
    func testPortKillConfirmationText() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }
        let record = PortRecord(port: 3000, pid: 42, processName: "node",
                                executablePath: nil, commandLine: nil,
                                binds: [PortBind(address: "*", family: .ipv4)])
        let c = CommandPaletteOptions.portKillConfirmation(for: record)
        XCTAssertEqual(c.title, "Kill process?")
        XCTAssertEqual(c.message, "node (port :3000 · PID 42) will be terminated.")
        XCTAssertEqual(c.confirmLabel, "Kill")
    }

    @MainActor
    func testPortOptionsCarryConfirmationOthersDoNot() {
        let record = PortRecord(port: 3000, pid: 42, processName: "node",
                                executablePath: nil, commandLine: nil,
                                binds: [PortBind(address: "*", family: .ipv4)])
        XCTAssertNotNil(CommandPaletteOptions.portOptions(records: [record]).first?.confirmation)
        XCTAssertNil(CommandPaletteOptions.keepAwakeOptions(isOn: false).first?.confirmation)
    }

    @MainActor
    func testIsOptionParentIncludesPortManager() {
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.portManager))
    }

    @MainActor
    func testPortOptionsSortedWithKillAffordance() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }

        let records = [
            PortRecord(port: 8080, pid: 43, processName: "java",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 3000, pid: 42, processName: "node",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let options = CommandPaletteOptions.portOptions(records: records)
        XCTAssertEqual(options.map(\.id), ["port.42.3000", "port.43.8080"])
        XCTAssertEqual(options.map(\.title), ["node", "java"])
        XCTAssertEqual(options.first?.subtitle, "Port :3000 · PID 42")
        XCTAssertEqual(options.first?.symbol, "xmark.circle.fill")
        XCTAssertFalse(options.contains { $0.role == .destructive })
    }

    @MainActor
    func testPortOptionsEmptyWhenNoRecords() {
        XCTAssertTrue(CommandPaletteOptions.portOptions(records: []).isEmpty)
    }

    @MainActor
    private func sampleOptions() -> [CommandPaletteOption] {
        [
            CommandPaletteOption(id: "a", title: "Alpha", symbol: "clock", perform: {}),
            CommandPaletteOption(id: "b", title: "Beta", symbol: "clock", perform: {}),
        ]
    }

    @MainActor
    func testRequestAndCancelConfirmation() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        XCTAssertFalse(state.isConfirming)
        let c = CommandPaletteConfirmation(title: "T", message: "M", confirmLabel: "Kill")
        state.requestConfirmation(c, perform: {})
        XCTAssertTrue(state.isConfirming)
        XCTAssertEqual(state.pendingConfirmation?.confirmation, c)
        state.cancelConfirmation()
        XCTAssertFalse(state.isConfirming)
        XCTAssertNil(state.pendingConfirmation)
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
    func testSecondLevelSearchMatchesSubtitle() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Ports", [
            CommandPaletteOption(id: "port.42.3000", title: "node",
                                 subtitle: "Port :3000 · PID 42", symbol: "xmark.circle.fill", perform: {}),
            CommandPaletteOption(id: "port.43.8080", title: "java",
                                 subtitle: "Port :8080 · PID 43", symbol: "xmark.circle.fill", perform: {}),
        ])
        state.query = "3000"
        XCTAssertEqual(state.flatEntries.map(\.id), ["option:port.42.3000"])
    }

    @MainActor
    func testEscapeAtRootClearsNonEmptyQuery() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "abc"
        state.selectedIndex = 3
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testEscapeAtRootWithEmptyQueryDismisses() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        XCTAssertEqual(state.handleEscape(), .dismiss)
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testEscapeTreatsWhitespaceOnlyQueryAsContent() {
        // Whitespace is content the user typed (the clear button shows for it
        // too), so Esc clears it first instead of closing / popping.
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "   "
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testEscapeInOptionsClearsNonEmptyQueryWithoutPopping() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        state.query = "bet"
        state.selectedIndex = 1
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertFalse(state.isAtRoot) // stays in the second level
    }

    @MainActor
    func testEscapeInOptionsWithEmptyQueryPopsToRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterOptions(parentTitle: "Keep Awake", sampleOptions())
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)
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

    // MARK: - Color format options (#3)

    @MainActor
    func testPickColorIsOptionParent() {
        XCTAssertTrue(CommandPaletteOptions.isOptionParent(.pickColor))
    }

    @MainActor
    func testColorFormatOptionsHaveStableIDsAndMarkCurrent() {
        let options = CommandPaletteOptions.colorFormatOptions(current: .rgb)
        XCTAssertEqual(
            options.map(\.id),
            ["pickColor.hex", "pickColor.rgb", "pickColor.hsl", "pickColor.swiftUI", "pickColor.css"]
        )
        XCTAssertEqual(options.filter(\.isChecked).map(\.id), ["pickColor.rgb"])
        XCTAssertFalse(options.contains { $0.role == .destructive })
    }
}
