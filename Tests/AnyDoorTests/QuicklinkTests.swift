import CoreGraphics
import SwiftData
import XCTest
@testable import AnyDoor

final class QuicklinkDestinationTests: XCTestCase {
    func testSchemeLessHostPortClassifiesAsWeb() throws {
        XCTAssertEqual(
            QuicklinkDestination.classify(link: "localhost:3000"),
            .web(try XCTUnwrap(URL(string: "http://localhost:3000")))
        )
    }

    func testTildePathClassifiesAsFolder() throws {
        let expanded = ("~/Bee/AnyDoor" as NSString).expandingTildeInPath
        var probedPaths: [String] = []

        XCTAssertEqual(
            QuicklinkDestination.classify(link: "~/Bee/AnyDoor") { path in
                probedPaths.append(path)
                return .directory
            },
            .folder(URL(fileURLWithPath: expanded))
        )
        XCTAssertEqual(probedPaths, [expanded])
    }

    func testPathWithSpacesClassifiesAsFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoor Quicklink Tests \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        XCTAssertEqual(
            QuicklinkDestination.classify(link: folder.path),
            .folder(folder)
        )
    }

    func testFilePathClassifiesWithInjectedProbe() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("quicklink-file-\(UUID().uuidString).txt")

        XCTAssertEqual(
            QuicklinkDestination.classify(link: file.path) { path in
                XCTAssertEqual(path, file.path)
                return .file
            },
            .file(file)
        )
    }

    func testQueryPlaceholderInFragmentClassifiesAsSearchTemplate() {
        XCTAssertEqual(
            QuicklinkDestination.classify(link: "https://example.com/search#q={query}"),
            .searchTemplate("https://example.com/search#q={query}")
        )
        XCTAssertTrue(QuicklinkDestination.isSearchTemplate(link: "https://example.com/search#q={query}"))
    }

    func testDeeplinkClassifiesByScheme() throws {
        XCTAssertEqual(
            QuicklinkDestination.classify(link: "slack://open"),
            .deeplink(try XCTUnwrap(URL(string: "slack://open")))
        )
    }
}

final class QuicklinkOpenerPlanTests: XCTestCase {
    func testMissingFilePlansFailure() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-quicklink-\(UUID().uuidString)")

        XCTAssertEqual(
            QuicklinkOpener.plan(link: missing.path),
            .fail(.missingFileSystem(missing))
        )
    }

    func testWebAndDeeplinkPlanDefaultOpen() throws {
        let github = try XCTUnwrap(URL(string: "https://github.com"))
        XCTAssertEqual(QuicklinkOpener.plan(link: "https://github.com"), .open(github))

        let slack = try XCTUnwrap(URL(string: "slack://open"))
        XCTAssertEqual(QuicklinkOpener.plan(link: "slack://open"), .open(slack))
    }

    func testOpenWithHitPlansApplicationOpen() throws {
        let github = try XCTUnwrap(URL(string: "https://github.com"))
        let code = URL(fileURLWithPath: "/Applications/Visual Studio Code.app")

        XCTAssertEqual(
            QuicklinkOpener.plan(
                link: "https://github.com",
                openWithBundleID: "com.microsoft.VSCode",
                applicationURLForBundleID: { $0 == "com.microsoft.VSCode" ? code : nil }
            ),
            .openWithApplication(github, applicationURL: code)
        )
    }

    func testOpenWithMissingPlansDefaultOpenWithWarning() throws {
        let github = try XCTUnwrap(URL(string: "https://github.com"))

        XCTAssertEqual(
            QuicklinkOpener.plan(
                link: "https://github.com",
                openWithBundleID: "com.microsoft.VSCode",
                applicationURLForBundleID: { _ in nil }
            ),
            .open(github, warning: .openWithAppMissing("com.microsoft.VSCode"))
        )
    }

    func testTemplateArgumentIsPercentEncodedAndReplacedEverywhere() throws {
        let planned = QuicklinkOpener.plan(
            link: "https://example.com/search?q={query}#{query}",
            argument: "任意 门"
        )

        XCTAssertEqual(
            planned,
            .open(try XCTUnwrap(URL(string: "https://example.com/search?q=%E4%BB%BB%E6%84%8F%20%E9%97%A8#%E4%BB%BB%E6%84%8F%20%E9%97%A8")))
        )
    }

    func testTemplateRejectsMissingAndEmptyArguments() {
        let link = "https://example.com/search?q={query}"

        XCTAssertEqual(QuicklinkOpener.plan(link: link), .fail(.missingArgument))
        XCTAssertEqual(QuicklinkOpener.plan(link: link, argument: "   "), .fail(.missingArgument))
        XCTAssertNil(QuicklinkOpener.substitutedTemplateLink(link: link, argument: ""))
    }
}

final class QuicklinkIconProviderSourceTests: XCTestCase {
    func testPinnedOpenWithAppWinsOverDestinationIcon() {
        let source = QuicklinkIconProvider.source(
            for: QuicklinkIconRequest(
                link: "https://github.com",
                openWithBundleID: "com.microsoft.VSCode"
            ),
            lookup: lookup(
                bundleApps: [
                    "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
                ]
            )
        )

        XCTAssertEqual(source, .appBundleID("com.microsoft.VSCode"))
    }

    func testMissingPinnedAppFallsThroughToFileSystemIcon() {
        let folder = URL(fileURLWithPath: "/tmp/AnyDoor")

        let source = QuicklinkIconProvider.source(
            for: QuicklinkIconRequest(link: folder.path, openWithBundleID: "missing.app"),
            lookup: lookup(fileExistence: [folder.path: .directory])
        )

        XCTAssertEqual(source, .fileSystem(path: folder.path))
    }

    func testFileSystemIconWinsForExistingFilesAndFolders() {
        let file = URL(fileURLWithPath: "/tmp/AnyDoor/README.md")
        let folder = URL(fileURLWithPath: "/tmp/AnyDoor")
        let lookup = lookup(fileExistence: [
            file.path: .file,
            folder.path: .directory,
        ])

        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: file.path, openWithBundleID: nil),
                lookup: lookup
            ),
            .fileSystem(path: file.path)
        )
        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: folder.path, openWithBundleID: nil),
                lookup: lookup
            ),
            .fileSystem(path: folder.path)
        )
    }

    func testDeeplinkHandlerIconAndUnhandledFallback() throws {
        let slackURL = try XCTUnwrap(URL(string: "slack://open"))
        let slackApp = URL(fileURLWithPath: "/Applications/Slack.app")
        let handled = lookup(handlers: [slackURL: slackApp])

        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: "slack://open", openWithBundleID: nil),
                lookup: handled
            ),
            .applicationURL(slackApp)
        )
        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: "unknownscheme://open", openWithBundleID: nil),
                lookup: lookup()
            ),
            .symbol("link")
        )
    }

    func testWebAndSearchTemplateUseFaviconHost() {
        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: "https://github.com", openWithBundleID: nil),
                lookup: lookup()
            ),
            .favicon(host: "github.com")
        )
        XCTAssertEqual(
            QuicklinkIconProvider.source(
                for: QuicklinkIconRequest(link: "https://github.com/search?q={query}", openWithBundleID: nil),
                lookup: lookup()
            ),
            .favicon(host: "github.com")
        )
    }

    private func lookup(
        fileExistence: [String: QuicklinkDestination.FileExistence] = [:],
        bundleApps: [String: URL] = [:],
        handlers: [URL: URL] = [:]
    ) -> QuicklinkIconLookup {
        QuicklinkIconLookup(
            fileExists: { path in fileExistence[path] ?? .none },
            applicationURLForBundleID: { bundleApps[$0] },
            applicationURLToOpen: { handlers[$0] }
        )
    }
}

@MainActor
final class QuicklinkStoreTests: XCTestCase {
    private var container: ModelContainer?

    private func makeStore(refreshHotkeys: @escaping @MainActor () -> Void = {}) throws -> QuicklinkStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Quicklink.self, configurations: config)
        self.container = container
        return QuicklinkStore(modelContext: container.mainContext, refreshHotkeys: refreshHotkeys)
    }

    func testCRUDPersistsRows() throws {
        let store = try makeStore()

        let row = try store.add(name: "AnyDoor 仓库", link: "~/Bee/AnyDoor")
        XCTAssertEqual(store.quicklinks.map(\.name), ["AnyDoor 仓库"])
        XCTAssertEqual(store.quicklinks.first?.link, "~/Bee/AnyDoor")

        try store.update(
            id: row.id,
            name: "AnyDoor",
            link: "https://github.com",
            openWithBundleID: "com.apple.Safari",
            hotkey: nil,
            isVisible: false
        )
        XCTAssertEqual(store.quicklinks.first?.name, "AnyDoor")
        XCTAssertEqual(store.quicklinks.first?.link, "https://github.com")
        XCTAssertEqual(store.quicklinks.first?.openWithBundleID, "com.apple.Safari")
        XCTAssertEqual(store.quicklinks.first?.isVisible, false)

        store.delete(id: row.id)
        XCTAssertTrue(store.quicklinks.isEmpty)
        XCTAssertTrue(try XCTUnwrap(container).mainContext.fetch(FetchDescriptor<Quicklink>()).isEmpty)
    }

    func testLinkMustBeNonEmpty() throws {
        let store = try makeStore()

        XCTAssertThrowsError(try store.add(name: "Empty", link: "   ")) { error in
            XCTAssertEqual(error as? QuicklinkStoreError, .linkRequired)
        }
    }

    func testWriteBeforeBootstrapThrowsNotConfigured() {
        let store = QuicklinkStore(modelContext: nil, refreshHotkeys: {})

        XCTAssertThrowsError(try store.add(name: "AnyDoor", link: "https://example.com")) { error in
            XCTAssertEqual(error as? QuicklinkStoreError, .notConfigured)
        }
    }

    func testOpenWithBundleIDIsNormalized() throws {
        let store = try makeStore()
        let row = try store.add(
            name: "Docs",
            link: "https://example.com",
            openWithBundleID: "  com.apple.Safari\n"
        )

        XCTAssertEqual(store.quicklinks.first?.openWithBundleID, "com.apple.Safari")

        try store.update(
            id: row.id,
            name: "Docs",
            link: "https://example.com",
            openWithBundleID: "   ",
            hotkey: nil,
            isVisible: true
        )

        XCTAssertNil(store.quicklinks.first?.openWithBundleID)
        XCTAssertEqual(
            QuicklinkIconRequest(link: "https://example.com", openWithBundleID: "  com.apple.Safari\n"),
            QuicklinkIconRequest(link: "https://example.com", openWithBundleID: "com.apple.Safari")
        )
    }

    func testHiddenRowsDoNotEnterPaletteButTemplatesDo() throws {
        let store = try makeStore()

        let visible = try store.add(name: "AnyDoor 仓库", link: "~/Bee/AnyDoor")
        let hidden = try store.add(name: "Hidden", link: "https://example.com", isVisible: false)
        let template = try store.add(
            name: "GitHub 搜索",
            link: "https://github.com/search?q={query}",
            keyword: "gh"
        )

        XCTAssertEqual(store.paletteEntries().map(\.title), ["AnyDoor 仓库", "GitHub 搜索"])
        XCTAssertEqual(store.paletteEntries().first?.source, .quicklink(id: visible.id))
        XCTAssertEqual(store.paletteEntries().last?.source, .quicklinkTemplate(id: template.id))
        XCTAssertEqual(store.paletteEntries().last?.searchAliases, ["gh"])
        XCTAssertEqual(
            store.paletteEntries().last?.quicklinkIcon,
            QuicklinkIconRequest(link: "https://github.com/search?q={query}", openWithBundleID: nil)
        )
        XCTAssertEqual(
            store.templateCandidates(),
            [
                QuicklinkTemplateCandidate(
                    id: template.id,
                    title: "GitHub 搜索",
                    keyword: "gh",
                    link: "https://github.com/search?q={query}",
                    openWithBundleID: nil
                )
            ]
        )

        store.setVisibility(id: visible.id, isVisible: false)
        XCTAssertEqual(store.paletteEntries().map(\.title), ["GitHub 搜索"])
        XCTAssertEqual(store.templateCandidates().map(\.id), [template.id])
        let storedIDs = store.quicklinks.map { $0.id }
        XCTAssertEqual(Set(storedIDs), Set([visible.id, hidden.id, template.id]))
    }

    func testKeywordMustBeUniqueCaseInsensitively() throws {
        let store = try makeStore()
        let github = try store.add(name: "GitHub 搜索", link: "https://github.com/search?q={query}", keyword: "gh")

        XCTAssertThrowsError(
            try store.add(name: "GitHub Issues", link: "https://github.com/issues?q={query}", keyword: "GH")
        ) { error in
            XCTAssertEqual(error as? QuicklinkStoreError, .keywordAlreadyUsed)
        }

        try store.update(
            id: github.id,
            name: "GitHub Search",
            link: "https://github.com/search?q={query}",
            keyword: "GH",
            hotkey: nil,
            isVisible: true
        )
        XCTAssertEqual(store.quicklinks.first?.keyword, "GH")

        let other = try store.add(name: "Other", link: "https://example.com", keyword: nil)
        XCTAssertThrowsError(
            try store.update(
                id: other.id,
                name: "Other",
                link: "https://example.com",
                keyword: " gh ",
                hotkey: nil,
                isVisible: true
            )
        ) { error in
            XCTAssertEqual(error as? QuicklinkStoreError, .keywordAlreadyUsed)
        }
    }

    func testHotkeyFieldsPersistAndRefreshOnMutation() throws {
        var refreshCount = 0
        let store = try makeStore {
            refreshCount += 1
        }
        let hotkey = HotkeyDescriptor(
            keyCode: 5,
            modifierFlags: Int(CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
        )

        let row = try store.add(name: "Docs", link: "https://example.com", hotkey: hotkey)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(store.quicklinks.first?.hotkeyDescriptor, hotkey)

        try store.update(
            id: row.id,
            name: "Docs",
            link: "https://example.com/docs",
            keyword: nil,
            hotkey: nil,
            isVisible: false
        )
        XCTAssertEqual(refreshCount, 2)
        XCTAssertNil(store.quicklinks.first?.hotkeyDescriptor)
        XCTAssertFalse(try XCTUnwrap(store.quicklinks.first).isVisible)

        store.delete(id: row.id)
        XCTAssertEqual(refreshCount, 3)
        XCTAssertTrue(store.quicklinks.isEmpty)
    }

    func testReorderPersistsThroughReloadedStore() throws {
        let store = try makeStore()
        let a = try store.add(name: "A", link: "https://a.example")
        let b = try store.add(name: "B", link: "https://b.example")
        let c = try store.add(name: "C", link: "https://c.example")

        store.reorder(by: [c.id, a.id, b.id])

        let reloaded = QuicklinkStore(modelContext: try XCTUnwrap(container).mainContext, refreshHotkeys: {})
        XCTAssertEqual(reloaded.quicklinks.map(\.name), ["C", "A", "B"])
    }
}
