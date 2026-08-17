import SwiftData
import XCTest
import PluginInterface
@testable import AnyDoor
@testable import HostsPlugin

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

        XCTAssertEqual(state.filteredSections.map(\.titleKey), ["commandPalette.section.ports"])
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
        XCTAssertEqual(L(.commandPaletteSearchPlaceholder), "Search commands, apps, quicklinks, ports")

        LocalizationManager.shared.preference = .zh
        XCTAssertEqual(L(.commandPaletteSearchPlaceholder), "搜索命令、应用、快速入口、端口")
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

        XCTAssertEqual(state.filteredSections.first?.titleKey, L10n.Key.commandPaletteSectionCalculator.rawValue)
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

        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == L10n.Key.commandPaletteSectionCalculator.rawValue })
    }

    // MARK: - Plugin row root search (hosts profiles, #4 / ADR-0007)

    @MainActor
    func testPluginRowSourceMakesStableID() {
        let sourceKey = PluginRowSourceKey(
            pluginID: NativePluginID(rawValue: "hosts"),
            localID: "profiles"
        )
        let descriptor = PluginRowDescriptor(
            id: "profile-1", title: "Dev", symbol: "circle", commit: .closeThenAct
        )
        XCTAssertEqual(
            PanelEntry.id(for: .pluginRow(sourceKey: sourceKey, descriptor: descriptor)),
            "pluginRow:hosts:profiles:profile-1"
        )
    }

    @MainActor
    func testQuicklinkSourceMakesStableID() {
        let id = UUID()
        XCTAssertEqual(PanelEntry.id(for: .quicklink(id: id)), "quicklink:\(id.uuidString)")
        XCTAssertEqual(PanelEntry.id(for: .quicklinkTemplate(id: id)), "quicklinkTemplate:\(id.uuidString)")
        XCTAssertEqual(
            PanelEntry.id(for: .quicklinkArgument(id: id, argument: "AnyDoor")),
            "quicklinkArgument:\(id.uuidString):AnyDoor"
        )
    }

    @MainActor
    func testQuicklinkNameQueryShowsMatchingRootEntry() throws {
        let id = UUID()
        let quicklink = PanelEntry(
            id: PanelEntry.id(for: .quicklink(id: id)),
            source: .quicklink(id: id),
            displayOrder: 100,
            isVisible: true,
            hotkey: nil,
            title: "AnyDoor 仓库",
            subtitle: "~/Bee/AnyDoor",
            symbol: "link",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
        let state = CommandPaletteState(
            sections: [CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [quicklink])],
            hyperFlags: 0
        )
        state.query = "any"

        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.source, .quicklink(id: id))
        XCTAssertEqual(entry.title, "AnyDoor 仓库")
    }

    @MainActor
    func testQuicklinkKeywordQueryShowsMatchingRootEntry() throws {
        let id = UUID()
        let quicklink = quicklinkEntry(
            id: id,
            title: "GitHub 搜索",
            link: "https://github.com/search?q={query}",
            keyword: "gh",
            isTemplate: true
        )
        let state = CommandPaletteState(
            sections: [CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [quicklink])],
            hyperFlags: 0
        )
        state.query = "gh"

        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.source, .quicklinkTemplate(id: id))
        XCTAssertEqual(entry.title, "GitHub 搜索")
    }

    @MainActor
    func testInlineQuicklinkArgumentResolverHitAndMissMatrix() throws {
        let id = UUID()
        let template = templateCandidate(
            id: id,
            title: "GitHub 搜索",
            link: "https://github.com/search?q={query}",
            keyword: "gh"
        )
        let plain = QuicklinkTemplateCandidate(
            id: UUID(),
            title: "Plain",
            keyword: "plain",
            link: "https://example.com"
        )

        let keyword = try XCTUnwrap(
            QuicklinkInlineArgumentResolver.resolve(query: "GH 任意 门", candidates: [template, plain])
        )
        XCTAssertEqual(keyword.quicklinkID, id)
        XCTAssertEqual(keyword.argument, "任意 门")
        XCTAssertEqual(keyword.substitutedLink, "https://github.com/search?q=%E4%BB%BB%E6%84%8F%20%E9%97%A8")

        let displayName = try XCTUnwrap(
            QuicklinkInlineArgumentResolver.resolve(query: "GitHub 搜索 AnyDoor", candidates: [template])
        )
        XCTAssertEqual(displayName.argument, "AnyDoor")

        XCTAssertNil(QuicklinkInlineArgumentResolver.resolve(query: "ghx AnyDoor", candidates: [template]))
        XCTAssertNil(QuicklinkInlineArgumentResolver.resolve(query: "plain AnyDoor", candidates: [plain]))
        XCTAssertNil(QuicklinkInlineArgumentResolver.resolve(query: "gh   ", candidates: [template]))
    }

    @MainActor
    func testInlineQuicklinkArgumentPinsSynthesizedRowAtTop() throws {
        let id = UUID()
        let template = quicklinkEntry(
            id: id,
            title: "GitHub 搜索",
            link: "https://github.com/search?q={query}",
            keyword: "gh",
            isTemplate: true,
            displaySubtitle: "Search GitHub"
        )
        let state = CommandPaletteState(
            sections: [CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [template])],
            hyperFlags: 0,
            quicklinkTemplateCandidates: [
                templateCandidate(
                    id: id,
                    title: "GitHub 搜索",
                    link: "https://github.com/search?q={query}",
                    keyword: "gh"
                )
            ]
        )
        state.query = "gh AnyDoor"

        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.title, "GitHub 搜索 — AnyDoor")
        XCTAssertEqual(entry.subtitle, "https://github.com/search?q=AnyDoor")
        guard case .quicklinkArgument(let quicklinkID, let argument) = entry.source else {
            return XCTFail("Expected a synthesized Quicklink argument row")
        }
        XCTAssertEqual(quicklinkID, id)
        XCTAssertEqual(argument, "AnyDoor")
    }

    @MainActor
    func testArgumentModeTransitionPolicyAndCommitEntry() throws {
        let id = UUID()
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 3

        state.enterArgumentInput(
            quicklinkID: id,
            title: "GitHub 搜索",
            link: "https://github.com/search?q={query}",
            openWithBundleID: "com.apple.Safari"
        )

        XCTAssertFalse(state.isAtRoot)
        XCTAssertTrue(state.isInArgumentInput)
        XCTAssertEqual(state.argumentInputTitle, "GitHub 搜索")
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertTrue(state.flatEntries.isEmpty)

        state.query = "AnyDoor"
        let entry = try XCTUnwrap(state.commitSelection())
        XCTAssertEqual(entry.title, "GitHub 搜索 — AnyDoor")
        XCTAssertEqual(entry.subtitle, "https://github.com/search?q=AnyDoor")
        XCTAssertEqual(entry.source, .quicklinkArgument(id: id, argument: "AnyDoor"))
        XCTAssertEqual(
            entry.quicklinkIcon,
            QuicklinkIconRequest(link: "https://github.com/search?q=AnyDoor", openWithBundleID: "com.apple.Safari")
        )

        state.query = "   "
        XCTAssertNil(state.commitSelection())
    }

    @MainActor
    func testArgumentModeEscapeAndPopPolicy() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let id = UUID()
        state.enterArgumentInput(quicklinkID: id, title: "GitHub 搜索", link: "https://github.com/search?q={query}")
        state.query = "AnyDoor"

        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.query, "")

        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)

        state.enterArgumentInput(quicklinkID: id, title: "GitHub 搜索", link: "https://github.com/search?q={query}")
        state.popToRoot()
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testTabAbsorbsQuicklinkKeywordIntoArgumentBadge() {
        let id = UUID()
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            quicklinkTemplateCandidates: [
                templateCandidate(
                    id: id,
                    title: "GitHub 搜索",
                    link: "https://github.com/search?q={query}",
                    keyword: "gh"
                )
            ]
        )

        // A bare, case-insensitive keyword is absorbed into a badge; the body clears.
        state.query = "GH"
        XCTAssertTrue(state.tryAbsorbQuicklinkKeyword())
        XCTAssertTrue(state.isInArgumentInput)
        XCTAssertEqual(state.argumentBadge, "gh")
        XCTAssertEqual(state.argumentInputTitle, "GitHub 搜索")
        XCTAssertEqual(state.query, "")

        // Typing the argument now yields the synthesized open row.
        state.query = "AnyDoor"
        XCTAssertEqual(state.flatEntries.first?.source, .quicklinkArgument(id: id, argument: "AnyDoor"))
    }

    @MainActor
    func testTabDoesNotAbsorbNonKeywordOrArgumentedQuery() {
        let id = UUID()
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            quicklinkTemplateCandidates: [
                templateCandidate(
                    id: id,
                    title: "GitHub 搜索",
                    link: "https://github.com/search?q={query}",
                    keyword: "gh"
                )
            ]
        )

        // Unknown keyword: no absorb, stays at root.
        state.query = "nope"
        XCTAssertFalse(state.tryAbsorbQuicklinkKeyword())
        XCTAssertTrue(state.isAtRoot)

        // Keyword plus an argument is not a bare keyword: no absorb (inline
        // resolution handles that case instead).
        state.query = "gh AnyDoor"
        XCTAssertFalse(state.tryAbsorbQuicklinkKeyword())
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testArgumentBadgeFallsBackToTitleWithoutKeyword() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterArgumentInput(
            quicklinkID: UUID(),
            title: "GitHub 搜索",
            link: "https://github.com/search?q={query}"
        )
        XCTAssertEqual(state.argumentBadge, "GitHub 搜索")
    }

    @MainActor
    func testProfileNameQueryShowsMatchingHostsProfile() throws {
        // Give this row source a real host so its "Active" subtitle resolves
        // through the shared catalog without mutating process-wide state.
        let container = try ModelContainer(
            for: Schema(HostsNativePlugin.modelSchemaTypes),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let host = PluginHostContext(services: CorePluginHost(modelContainer: container))
        let previousLanguage = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = .en
        defer { LocalizationManager.shared.preference = previousLanguage }

        let dev = HostProfile(name: "Dev", isActive: true)
        let prod = HostProfile(name: "Prod", isActive: false)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            rowSources: [hostsRowSourceRegistration(profiles: [dev, prod], host: host)]
        )
        state.query = "Dev"

        XCTAssertEqual(state.filteredSections.first?.titleKey, "commandPalette.section.hosts")
        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(entry.title, "Dev")
        XCTAssertEqual(entry.subtitle, "Active")
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a plugin row entry")
        }
        XCTAssertEqual(descriptor.id, dev.id.uuidString)
        XCTAssertEqual(descriptor.commit, .closeThenAct)
    }

    @MainActor
    func testInactiveProfileHasNoActiveSubtitle() throws {
        let prod = HostProfile(name: "Prod", isActive: false)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            rowSources: [hostsRowSourceRegistration(profiles: [prod])]
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
            rowSources: [hostsRowSourceRegistration(profiles: [dev])]
        )
        XCTAssertTrue(state.filteredSections.isEmpty)
    }

    @MainActor
    func testUpdatingPluginSurfacesDropsUnregisteredRows() {
        let dev = HostProfile(name: "Dev", isActive: true)
        let state = CommandPaletteState(
            sections: [],
            hyperFlags: 0,
            rowSources: [hostsRowSourceRegistration(profiles: [dev])]
        )
        state.query = "Dev"
        XCTAssertFalse(state.filteredSections.isEmpty)

        state.updateSections([], pluginRowSources: [])

        XCTAssertTrue(state.filteredSections.isEmpty)
    }

    @MainActor
    private func hostsRowSourceRegistration(
        profiles: [HostProfile],
        host: PluginHostContext? = nil
    ) -> CommandPaletteExtensions.RowSourceRegistration {
        CommandPaletteExtensions.RowSourceRegistration(
            key: PluginRowSourceKey(
                pluginID: HostsNativePlugin.pluginID,
                localID: HostProfileRowSource.sourceID
            ),
            sectionTitleKey: "commandPalette.section.hosts",
            source: HostProfileRowSource(
                host: host,
                profiles: { profiles },
                reload: {},
                setActive: { _, _ in }
            )
        )
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
            state.filteredSections.first { $0.titleKey == L10n.Key.commandPaletteSectionDevTools.rawValue }
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
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == L10n.Key.commandPaletteSectionDevTools.rawValue })
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
        XCTAssertEqual(sections.map(\.titleKey), [L10n.Key.commandPaletteSectionDevTools.rawValue])
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
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [])
        state.query = "3 ft to m"

        let section = try XCTUnwrap(state.filteredSections.first)
        XCTAssertEqual(section.titleKey, L10n.Key.commandPaletteSectionConversion.rawValue)
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
            rowSources: [],
            currencyRatesProvider: { table }
        )
        state.query = "100 usd to eur"

        let entry = try XCTUnwrap(
            state.filteredSections.first { $0.titleKey == L10n.Key.commandPaletteSectionConversion.rawValue }?.entries.first
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
            rowSources: [],
            currencyRatesProvider: { nil }
        )
        state.query = "100 usd to eur"
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == L10n.Key.commandPaletteSectionConversion.rawValue })
    }

    @MainActor
    func testPlainSearchDoesNotShowConversionSection() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [])
        state.query = "settings"
        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == L10n.Key.commandPaletteSectionConversion.rawValue })
    }

    // MARK: - Currency toolbar visibility

    @MainActor
    func testCurrencyContextTrueForCurrencyRow() {
        let table = RateTable(base: "USD", rates: ["EUR": 0.925], date: "2026-06-13")
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, rowSources: [], currencyRatesProvider: { table }
        )
        state.query = "100 usd to eur"
        XCTAssertTrue(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextTrueForCurrencyQueryWithoutRates() {
        // No rates yet: still show the toolbar so the user can refresh to recover.
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, rowSources: [], currencyRatesProvider: { nil }
        )
        state.query = "100 usd to eur"
        XCTAssertTrue(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForUnitConversion() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [])
        state.query = "3 ft to m"
        XCTAssertFalse(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForPlainSearch() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [])
        state.query = "settings"
        XCTAssertFalse(state.isCurrencyContext)
    }

    @MainActor
    func testCurrencyContextFalseForUnknownCodesWhenRatesPresent() {
        let table = RateTable(base: "USD", rates: ["EUR": 0.925], date: "2026-06-13")
        let state = CommandPaletteState(
            sections: [], hyperFlags: 0, rowSources: [], currencyRatesProvider: { table }
        )
        state.query = "100 abc to xyz"
        XCTAssertFalse(state.isCurrencyContext)
    }

    // MARK: - Prefix ranking

    @MainActor
    func testTitlePrefixOutranksLaterSubstringAcrossSections() {
        let keepAwake = titledEntry("Keep Awake", bundleID: "keep-awake")
        let warp = titledEntry("Warp", bundleID: "dev.warp.Warp")
        let state = CommandPaletteState(
            sections: [
                CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [keepAwake]),
                CommandPaletteSection(titleKey: .commandPaletteSectionApplications, entries: [warp]),
            ],
            hyperFlags: 0,
            rowSources: []
        )
        state.query = "wa"

        XCTAssertEqual(state.flatEntries.map(\.title), ["Warp", "Keep Awake"])
        XCTAssertEqual(
            state.filteredSections.map(\.titleKey),
            [
                L10n.Key.commandPaletteSectionApplications.rawValue,
                L10n.Key.commandPaletteSectionCommands.rawValue,
            ]
        )
    }

    @MainActor
    func testPrefixRankingIsCaseInsensitiveAndNormalized() {
        let keepAwake = titledEntry("keep awake", bundleID: "keep-awake")
        let warp = titledEntry("WARP", bundleID: "dev.warp.Warp")
        let state = CommandPaletteState(
            sections: [
                CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [keepAwake]),
                CommandPaletteSection(titleKey: .commandPaletteSectionApplications, entries: [warp]),
            ],
            hyperFlags: 0,
            rowSources: []
        )
        state.query = "  Wa  "

        XCTAssertEqual(state.flatEntries.map(\.title), ["WARP", "keep awake"])
    }

    @MainActor
    func testEqualRankKeepsOriginalSectionAndEntryOrder() {
        let keepAwake = titledEntry("Keep Awake", bundleID: "keep-awake")
        let alwaysOn = titledEntry("Always On", bundleID: "always-on")
        let watch = titledEntry("Watch", bundleID: "com.apple.watch")
        let warp = titledEntry("Warp", bundleID: "dev.warp.Warp")
        let state = CommandPaletteState(
            sections: [
                CommandPaletteSection(
                    titleKey: .commandPaletteSectionCommands,
                    entries: [keepAwake, alwaysOn]
                ),
                CommandPaletteSection(
                    titleKey: .commandPaletteSectionApplications,
                    entries: [watch, warp]
                ),
            ],
            hyperFlags: 0,
            rowSources: []
        )
        state.query = "wa"

        XCTAssertEqual(state.flatEntries.map(\.title), ["Watch", "Warp", "Keep Awake", "Always On"])
    }

    @MainActor
    func testEmptyQueryKeepsOriginalSectionOrder() {
        let keepAwake = titledEntry("Keep Awake", bundleID: "keep-awake")
        let warp = titledEntry("Warp", bundleID: "dev.warp.Warp")
        let state = CommandPaletteState(
            sections: [
                CommandPaletteSection(titleKey: .commandPaletteSectionCommands, entries: [keepAwake]),
                CommandPaletteSection(titleKey: .commandPaletteSectionApplications, entries: [warp]),
            ],
            hyperFlags: 0,
            rowSources: []
        )

        XCTAssertEqual(state.flatEntries.map(\.title), ["Keep Awake", "Warp"])
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

    private func quicklinkEntry(
        id: UUID,
        title: String,
        link: String,
        keyword: String?,
        isTemplate: Bool,
        displaySubtitle: String? = nil
    ) -> PanelEntry {
        let source: PanelEntry.Source = isTemplate ? .quicklinkTemplate(id: id) : .quicklink(id: id)
        return PanelEntry(
            id: PanelEntry.id(for: source),
            source: source,
            displayOrder: 100,
            isVisible: true,
            hotkey: nil,
            title: title,
            subtitle: displaySubtitle ?? link,
            searchAliases: keyword.map { [$0] } ?? [],
            symbol: "link",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
    }

    private func templateCandidate(
        id: UUID,
        title: String,
        link: String,
        keyword: String?
    ) -> QuicklinkTemplateCandidate {
        QuicklinkTemplateCandidate(id: id, title: title, keyword: keyword, link: link)
    }

    private func titledEntry(_ title: String, bundleID: String) -> PanelEntry {
        .paletteRow(
            source: .installedApp(bundleID: bundleID, path: "/Applications/\(bundleID).app"),
            displayOrder: 0,
            title: title,
            symbol: "app.fill"
        )
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
