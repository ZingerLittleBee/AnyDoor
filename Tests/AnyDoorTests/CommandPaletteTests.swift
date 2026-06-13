import XCTest
@testable import AnyDoor

final class CommandPaletteTests: XCTestCase {
    @MainActor
    func testEmptyQueryDoesNotShowPortProcesses() async {
        let inventory = PortInventory(
            scanner: StubScanner(records: [
                portRecord(port: 3000, pid: 42, processName: "node")
            ]),
            defaults: isolatedDefaults()
        )
        await inventory.refresh()

        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            portInventory: inventory
        )

        XCTAssertTrue(state.filteredSections.isEmpty)
        XCTAssertTrue(state.flatEntries.isEmpty)
    }

    @MainActor
    func testPortNumberQueryShowsMatchingPortProcess() async throws {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .zh
        defer { LocalizationManager.shared.preference = previousLanguage }

        let inventory = PortInventory(
            scanner: StubScanner(records: [
                portRecord(port: 3000, pid: 42, processName: "node"),
                portRecord(port: 8080, pid: 43, processName: "java"),
            ]),
            defaults: isolatedDefaults()
        )
        await inventory.refresh()

        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            portInventory: inventory
        )
        state.query = "3000"

        XCTAssertEqual(state.filteredSections.map(\.titleKey.rawValue), ["commandPalette.section.ports"])
        XCTAssertEqual(state.flatEntries.count, 1)

        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.id, "port:42:3000")
        XCTAssertEqual(entry.title, "node")
        XCTAssertEqual(entry.subtitle, "端口 :3000 · PID 42")

        guard case .portRecord(let record) = entry.source else {
            return XCTFail("Expected a port record command palette entry")
        }
        XCTAssertEqual(record.port, 3000)
        XCTAssertEqual(record.pid, 42)
    }

    @MainActor
    func testSearchPlaceholderMentionsCommandsAppsAndPorts() {
        let previousLanguage = LocalizationManager.shared.preference
        defer { LocalizationManager.shared.preference = previousLanguage }

        LocalizationManager.shared.preference = .en
        XCTAssertEqual(L(.commandPaletteSearchPlaceholder), "Search commands, apps, ports")

        LocalizationManager.shared.preference = .zh
        XCTAssertEqual(L(.commandPaletteSearchPlaceholder), "搜索命令、应用、端口")
    }

    @MainActor
    func testPortKillToastMentionsProcessAndPortOnSuccess() {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .zh
        defer { LocalizationManager.shared.preference = previousLanguage }

        let style = CommandPalettePortKillToast.style(
            for: portRecord(port: 3000, pid: 42, processName: "node"),
            result: .success
        )

        XCTAssertEqual(style.message, "已结束 node（:3000）")
    }

    @MainActor
    func testPortKillToastExplainsPermissionFailure() {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .zh
        defer { LocalizationManager.shared.preference = previousLanguage }

        let style = CommandPalettePortKillToast.style(
            for: portRecord(port: 80, pid: 42, processName: "root-thing"),
            result: .failure(.permissionDenied)
        )

        XCTAssertEqual(style.message, "结束 root-thing 失败：权限不足")
    }

    @MainActor
    func testCalcExpressionShowsCalculatorSectionAtTop() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "1+2"

        XCTAssertEqual(state.filteredSections.first?.titleKey, .commandPaletteSectionCalculator)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .calcResult(let result) = entry.source else {
            return XCTFail("Expected a calc result entry")
        }
        XCTAssertEqual(result.copyText, "3")
        XCTAssertEqual(entry.title, "3")
        XCTAssertEqual(entry.subtitle, "1+2")
        XCTAssertEqual(entry.symbol, "function")
    }

    @MainActor
    func testForcePrefixCalculatesBareNumber() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "=8080"

        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .calcResult(let result) = entry.source else {
            return XCTFail("Expected a calc result entry")
        }
        XCTAssertEqual(result.copyText, "8080")
    }

    @MainActor
    func testBareNumberDoesNotShowCalculatorSection() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "8080"

        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == .commandPaletteSectionCalculator })
    }

    // MARK: - Hosts profile root search (#4)

    @MainActor
    func testHostProfileSourceMakesStableID() {
        let id = UUID()
        XCTAssertEqual(PanelEntry.id(for: .hostProfile(id: id)), "hostProfile:\(id.uuidString)")
    }

    @MainActor
    func testProfileNameQueryShowsMatchingHostsProfile() throws {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previousLanguage }

        let dev = HostProfile(name: "Dev", isActive: true)
        let prod = HostProfile(name: "Prod", isActive: false)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            hostProfilesProvider: { [dev, prod] }
        )
        state.query = "Dev"

        XCTAssertEqual(state.filteredSections.first?.titleKey, .commandPaletteSectionHosts)
        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.title, "Dev")
        XCTAssertEqual(entry.subtitle, "Active")
        guard case .hostProfile(let id) = entry.source else {
            return XCTFail("Expected a host profile entry")
        }
        XCTAssertEqual(id, dev.id)
    }

    @MainActor
    func testInactiveProfileHasNoActiveSubtitle() throws {
        let prod = HostProfile(name: "Prod", isActive: false)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            hostProfilesProvider: { [prod] }
        )
        state.query = "Prod"
        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertNil(entry.subtitle)
    }

    @MainActor
    func testEmptyQueryDoesNotShowHostsProfiles() {
        let dev = HostProfile(name: "Dev", isActive: true)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            hostProfilesProvider: { [dev] }
        )
        XCTAssertTrue(state.filteredSections.isEmpty)
    }

    private struct StubScanner: PortScanning {
        let records: [PortRecord]

        func scanTCPListening() async throws -> [PortRecord] {
            records
        }

        func kill(pid: pid_t, signal: Int32) -> SignalResult {
            .success
        }
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "CommandPaletteTests-\(UUID().uuidString)")!
    }

    private func portRecord(port: UInt16, pid: pid_t, processName: String) -> PortRecord {
        PortRecord(
            port: port,
            pid: pid,
            processName: processName,
            executablePath: nil,
            commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
    }
}
