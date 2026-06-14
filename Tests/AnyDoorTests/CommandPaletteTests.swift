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

    // MARK: - Developer tools root search

    @MainActor
    func testDevToolSourceMakesStableID() {
        let result = DevToolResult(toolID: "hash.md5", output: "abc")
        XCTAssertEqual(PanelEntry.id(for: .devTool(result)), "devTool:hash.md5:abc")
    }

    @MainActor
    func testDevToolKeywordShowsDeveloperToolsSection() throws {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previousLanguage }

        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "md5 abc"

        let section = try XCTUnwrap(
            state.filteredSections.first { $0.titleKey == .commandPaletteSectionDevTools }
        )
        let entry = try XCTUnwrap(section.entries.first { $0.subtitle == "MD5" })
        XCTAssertEqual(entry.title, "900150983cd24fb0d6963f7d28e17f72")
        guard case .devTool(let result) = entry.source else {
            return XCTFail("Expected a dev-tool entry")
        }
        XCTAssertEqual(result.toolID, "hash.md5")
    }

    @MainActor
    func testPlainTextDoesNotShowDeveloperToolsSection() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "hello"
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == .commandPaletteSectionDevTools })
    }

    // MARK: - Dev-tool scope badge

    @MainActor
    func testSpaceAbsorbsKeywordIntoScope() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base64 "
        state.absorbDevToolScopeIfNeeded()
        XCTAssertEqual(state.activeDevToolScope, .base64)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testPastedKeywordWithBodyAbsorbsAndKeepsBody() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "md5 hello world"
        state.absorbDevToolScopeIfNeeded()
        XCTAssertEqual(state.activeDevToolScope, .md5)
        XCTAssertEqual(state.query, "hello world")
    }

    @MainActor
    func testNonKeywordDoesNotAbsorb() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "hello world"
        state.absorbDevToolScopeIfNeeded()
        XCTAssertNil(state.activeDevToolScope)
        XCTAssertEqual(state.query, "hello world")
    }

    @MainActor
    func testTabAbsorbsBareKeyword() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "sha256"
        XCTAssertTrue(state.tryAbsorbDevToolScope())
        XCTAssertEqual(state.activeDevToolScope, .sha256)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testTabDoesNotAbsorbNonKeyword() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "hello"
        XCTAssertFalse(state.tryAbsorbDevToolScope())
        XCTAssertNil(state.activeDevToolScope)
    }

    @MainActor
    func testScopeShowsExclusiveDeveloperToolsSection() throws {
        let app = CommandPaletteSection(
            titleKey: .commandPaletteSectionApplications,
            entries: [PanelEntry(
                id: "x", source: .installedApp(bundleID: "com.x", path: "/x"),
                displayOrder: 0, isVisible: true, hotkey: nil, title: "Xcode",
                subtitle: nil, symbol: "app", kind: .action, toggleState: nil, permission: .notRequired
            )]
        )
        let state = CommandPaletteState(sections: [app], hyperFlags: 0)
        state.query = "base64 "
        state.absorbDevToolScopeIfNeeded()
        state.query = "hello"

        let sections = state.filteredSections
        XCTAssertEqual(sections.map(\.titleKey), [.commandPaletteSectionDevTools])
        let entry = try XCTUnwrap(sections.first?.entries.first { $0.subtitle == "Base64 Encode" || $0.subtitle == "Base64 编码" })
        XCTAssertEqual(entry.title, "aGVsbG8=")
    }

    @MainActor
    func testRemoveScopeClearsBadgeAndBody() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "url "
        state.absorbDevToolScopeIfNeeded()
        state.removeDevToolScope()
        XCTAssertNil(state.activeDevToolScope)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testEscapeWithScopeAndBodyClearsBodyFirst() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base64 "
        state.absorbDevToolScopeIfNeeded()
        state.query = "abc"
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertEqual(state.activeDevToolScope, .base64)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testEscapeWithScopeAndEmptyBodyRemovesScope() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base64 "
        state.absorbDevToolScopeIfNeeded()
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertNil(state.activeDevToolScope)
    }

    // MARK: - Dev-tool keyword completion hints

    @MainActor
    func testScopeSuggestionsMatchKeywordPrefix() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        XCTAssertEqual(state.devToolScopeSuggestions(matching: "base"), [.base64])
        XCTAssertEqual(state.devToolScopeSuggestions(matching: "sha"), [.sha1, .sha256])
        XCTAssertEqual(state.devToolScopeSuggestions(matching: "md"), [.md5])
    }

    @MainActor
    func testScopeSuggestionsEmptyForEmptyOrNonPrefix() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        XCTAssertTrue(state.devToolScopeSuggestions(matching: "").isEmpty)
        XCTAssertTrue(state.devToolScopeSuggestions(matching: "zzz").isEmpty)
    }

    @MainActor
    func testNoSuggestionsWhileAlreadyScoped() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base64 "
        state.absorbDevToolScopeIfNeeded()
        XCTAssertTrue(state.devToolScopeSuggestions(matching: "base").isEmpty)
    }

    @MainActor
    func testPrefixSurfacesSuggestionEntryAtTop() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base"
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .devToolScopeSuggestion(let scope) = entry.source else {
            return XCTFail("Expected a scope suggestion entry")
        }
        XCTAssertEqual(scope, .base64)
        XCTAssertEqual(entry.title, "Base64")
    }

    @MainActor
    func testCommittingSuggestionEntersScope() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "base"
        state.enterDevToolScope(.base64)
        XCTAssertEqual(state.activeDevToolScope, .base64)
        XCTAssertEqual(state.query, "")
    }

    @MainActor
    func testScopeTipsResolveForEveryScope() {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previous }
        for scope in DevToolScope.allCases {
            let hint = CommandPalettePicker.scopeHint(for: scope)
            XCTAssertFalse(hint.example.isEmpty, "\(scope) example is empty")
            XCTAssertFalse(L(hint.key).isEmpty, "\(scope) hint is not localized")
        }
    }

    // MARK: - Inline conversions

    @MainActor
    func testUnitConversionSurfacesConversionSection() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, hostProfilesProvider: { [] })
        state.query = "3 ft to m"

        let section = try XCTUnwrap(state.filteredSections.first)
        XCTAssertEqual(section.titleKey, .commandPaletteSectionConversion)
        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.title, "0.9144 m")
        XCTAssertEqual(entry.subtitle, "3 ft")
        guard case .conversion(let result) = entry.source else {
            return XCTFail("Expected a conversion entry")
        }
        XCTAssertEqual(result.kind, .unit)
        XCTAssertEqual(result.copyText, "0.9144")
    }

    @MainActor
    func testConversionSourceMakesStableID() {
        let result = ConversionResult(
            kind: .unit, value: 0.9144, display: "0.9144 m",
            copyText: "0.9144", detail: "3 ft", symbol: "ruler"
        )
        XCTAssertEqual(PanelEntry.id(for: .conversion(result)), "conversion:unit:0.9144:0.9144 m")
    }

    @MainActor
    func testCurrencyConversionUsesInjectedRatesAndLocalizedSubtitle() throws {
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previousLanguage }

        let table = RateTable(base: "USD", rates: ["EUR": 0.925], date: "2026-06-13")
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            hostProfilesProvider: { [] },
            currencyRatesProvider: { table }
        )
        state.query = "100 usd to eur"

        let entry = try XCTUnwrap(
            state.filteredSections.first { $0.titleKey == .commandPaletteSectionConversion }?.entries.first
        )
        XCTAssertEqual(entry.title, "92.50 EUR")
        XCTAssertEqual(entry.subtitle, "as of 2026-06-13")
        guard case .conversion(let result) = entry.source else {
            return XCTFail("Expected a conversion entry")
        }
        XCTAssertEqual(result.copyText, "92.50")
    }

    @MainActor
    func testCurrencyConversionAbsentWithoutRates() {
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            hostProfilesProvider: { [] },
            currencyRatesProvider: { nil }
        )
        state.query = "100 usd to eur"
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == .commandPaletteSectionConversion })
    }

    @MainActor
    func testPlainSearchDoesNotShowConversionSection() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, hostProfilesProvider: { [] })
        state.query = "settings"
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == .commandPaletteSectionConversion })
    }

    // MARK: - Currency toolbar visibility

    @MainActor
    func testCurrencyContextTrueForCurrencyRow() {
        let table = RateTable(base: "USD", rates: ["EUR": 0.925], date: "2026-06-13")
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, hostProfilesProvider: { [] }, currencyRatesProvider: { table }
        )
        state.query = "100 usd to eur"
        XCTAssertTrue(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextTrueForCurrencyQueryWithoutRates() {
        // No rates yet: still show the toolbar so the user can refresh to recover.
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, hostProfilesProvider: { [] }, currencyRatesProvider: { nil }
        )
        state.query = "100 usd to eur"
        XCTAssertTrue(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForUnitConversion() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, hostProfilesProvider: { [] })
        state.query = "3 ft to m"
        XCTAssertFalse(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForPlainSearch() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, hostProfilesProvider: { [] })
        state.query = "settings"
        XCTAssertFalse(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForUnknownCodesWhenRatesPresent() {
        let table = RateTable(base: "USD", rates: ["EUR": 0.925], date: "2026-06-13")
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, hostProfilesProvider: { [] }, currencyRatesProvider: { table }
        )
        state.query = "100 abc to xyz"
        XCTAssertFalse(state.isCurrencyContext)
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
