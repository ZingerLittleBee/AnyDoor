import XCTest
@testable import AnyDoor

final class CommandPaletteTests: XCTestCase {
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
