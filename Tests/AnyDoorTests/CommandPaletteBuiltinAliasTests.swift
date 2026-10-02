import SwiftData
import XCTest
import PluginInterface
@testable import AnyDoor

/// Root command-palette search over real builtin entries: the catalog
/// titles, the aliases `PanelStore.rebuild()` copies from
/// `BuiltinItem.paletteAliases`, and the production section order.
@MainActor
final class CommandPaletteBuiltinAliasTests: XCTestCase {

    func testScreenshotIsFoundByEveryNameInEitherLanguage() throws {
        for language in [LanguagePreference.en, .zh] {
            try withLanguage(language) {
                let state = try makePalette()
                for query in ["capture", "screenshot", "region", "截图", "截屏", "区域"] {
                    state.query = query
                    XCTAssertTrue(
                        state.flatEntries.map(\.id).contains(Self.screenshot),
                        "\(language) \(query)"
                    )
                }
            }
        }
    }

    func testScreenshotLeadsItsOwnNameInEachLanguage() throws {
        // English macOS lists its Screenshot app under the same name, so Return
        // on "screenshot" must open AnyDoor's Screenshot, not the app.
        try withLanguage(.en) {
            let systemScreenshot = Self.app("com.apple.screenshot.launcher", title: "Screenshot")
            let state = try makePalette(apps: [systemScreenshot])
            state.query = "screenshot"
            let ids = state.flatEntries.map(\.id)
            XCTAssertEqual(ids.first, Self.screenshot)
            XCTAssertTrue(ids.contains(systemScreenshot.id))
        }
        try withLanguage(.zh) {
            let state = try makePalette(apps: Self.chineseMacApps)
            state.query = "截图"
            XCTAssertEqual(state.flatEntries.first?.id, Self.screenshot)
        }
    }

    func testAliasHitStaysBelowTitlePrefixHits() throws {
        try withLanguage(.en) {
            let state = try makePalette()
            state.query = "capture"
            let ids = state.flatEntries.map(\.id)
            let screenshotIndex = try XCTUnwrap(ids.firstIndex(of: Self.screenshot))
            let windowIndex = try XCTUnwrap(ids.firstIndex(of: "builtin:captureWindow"))
            let fullscreenIndex = try XCTUnwrap(ids.firstIndex(of: "builtin:captureFullscreen"))
            XCTAssertLessThan(windowIndex, screenshotIndex)
            XCTAssertLessThan(fullscreenIndex, screenshotIndex)
        }
    }

    func testOtherAliasedCommandsAreFoundInEitherLanguage() throws {
        let expectations: [(query: String, id: String)] = [
            ("ocr", "builtin:ocr"),
            ("录屏", "builtin:recordScreen"),
            ("recording", "builtin:recordScreen"),
            ("timer", "builtin:captureTimer"),
            ("延时", "builtin:captureTimer"),
            ("scan", "builtin:qrcode"),
            ("扫描", "builtin:qrcode"),
            ("qr", "builtin:qrcode"),
            ("二维码", "builtin:qrcode"),
        ]
        for language in [LanguagePreference.en, .zh] {
            try withLanguage(language) {
                let state = try makePalette()
                for (query, id) in expectations {
                    state.query = query
                    XCTAssertTrue(state.flatEntries.map(\.id).contains(id), "\(language) \(query)")
                }
            }
        }
    }

    func testChineseUIKeepsAnAppFoundByItsEnglishNameOnTop() throws {
        // On a Chinese Mac people open apps by their English names, which
        // reach the palette as app aliases. Builtin aliases sit in earlier
        // sections, so a mid-word hit ("ding" or "co" inside "screen
        // recording") would put Record Screen above the app.
        try withLanguage(.zh) {
            let state = try makePalette(apps: Self.chineseMacApps)
            let expectations: [(query: String, id: String)] = [
                ("ding", "installedApp:com.alibaba.DingTalkMac"),
                ("din", "installedApp:com.alibaba.DingTalkMac"),
                ("di", "installedApp:com.alibaba.DingTalkMac"),
                ("in", "installedApp:com.alibaba.DingTalkMac"),
                ("co", "installedApp:com.apple.dt.Xcode"),
            ]
            for (query, id) in expectations {
                state.query = query
                XCTAssertEqual(state.flatEntries.first?.id, id, query)
            }
            // "sho" sits inside "screenshot" but starts none of 截图's aliases.
            state.query = "sho"
            XCTAssertFalse(state.flatEntries.map(\.id).contains(Self.screenshot), "sho")
        }
    }

    // MARK: - Fixture

    private static let screenshot = "builtin:screenshot"

    /// Installed apps as a Chinese macOS names them, with the English names
    /// `InstalledAppsScanner` keeps as aliases.
    private static var chineseMacApps: [PanelEntry] {
        [
            app("com.apple.screenshot.launcher", title: "截屏", aliases: ["Screenshot"]),
            app("com.alibaba.DingTalkMac", title: "钉钉", aliases: ["DingTalk"]),
            app("com.apple.dt.Xcode", title: "Xcode"),
        ]
    }

    private func withLanguage(
        _ language: LanguagePreference,
        _ body: () throws -> Void
    ) rethrows {
        let previous = LocalizationManager.shared.preference
        LocalizationManager.shared.preference = language
        defer { LocalizationManager.shared.preference = previous }
        try body()
    }

    /// A palette over every builtin, seeded in its default order and
    /// visibility like a fresh install (without the seeder's
    /// UserDefaults-gated migrations), followed by `apps`.
    private func makePalette(apps: [PanelEntry] = []) throws -> CommandPaletteState {
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        for item in BuiltinItem.allCases {
            container.mainContext.insert(BuiltinPreference(
                itemKey: item.rawValue,
                isVisible: item.defaultVisibility,
                displayOrder: item.defaultOrder
            ))
        }
        try container.mainContext.save()
        let store = PanelStore()
        store.bootstrap(modelContainer: container, providers: [])
        return CommandPaletteState(
            sections: Self.sections(from: store, apps: apps),
            hyperFlags: 0,
            rowSources: [],
            currencyRatesProvider: { nil }
        )
    }

    /// Root sections in production order. Keep this in step with
    /// `CommandPaletteWindowController.collectSections`: Commands (builtins no
    /// themed group claims), the groups in `BuiltinGroup.themedDefaultOrder`,
    /// Window Layout, and Applications last. Equal ranks keep this order, so
    /// it decides ties such as AnyDoor's Screenshot against the macOS
    /// Screenshot app. Submenus and Brightness, which `collectSections` lists
    /// only through `CommandPaletteExtensions`, are left out; no query here
    /// targets them.
    private static func sections(from store: PanelStore, apps: [PanelEntry]) -> [CommandPaletteSection] {
        let commands = store.topLevelEntries.filter { entry in
            guard entry.isVisible, let item = builtinItem(of: entry) else { return false }
            return item.kind == .toggle || item.kind == .action
        }
        let grouped = BuiltinGroup.themedDefaultOrder.reduce(into: Set<BuiltinItem>()) {
            $0.formUnion($1.members)
        }
        var sections = [CommandPaletteSection(
            titleKey: .commandPaletteSectionCommands,
            entries: commands.filter { builtinItem(of: $0).map { !grouped.contains($0) } ?? true }
        )]
        for group in BuiltinGroup.themedDefaultOrder {
            sections.append(CommandPaletteSection(
                titleKey: group.titleKey,
                entries: commands.filter { builtinItem(of: $0).map(group.members.contains) ?? false }
            ))
        }
        sections.append(CommandPaletteSection(
            titleKey: .commandPaletteSectionWindowLayout,
            entries: store.windowLayoutChildren.filter(\.isVisible)
        ))
        sections.append(CommandPaletteSection(titleKey: .commandPaletteSectionApplications, entries: apps))
        return sections
    }

    private static func builtinItem(of entry: PanelEntry) -> BuiltinItem? {
        if case .builtin(let item) = entry.source { return item }
        return nil
    }

    /// An installed app that no shortcut binds, as `collectSections` lists it.
    private static func app(_ bundleID: String, title: String, aliases: [String] = []) -> PanelEntry {
        .paletteRow(
            source: .installedApp(bundleID: bundleID, path: "/Applications/\(title).app"),
            displayOrder: 1_000_000,
            title: title,
            searchAliases: aliases,
            symbol: "app.fill",
            kind: .submenu
        )
    }
}
