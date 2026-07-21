import XCTest
import PluginInterface
@testable import AnyDoor

/// Pure-policy tests for the palette state added in ticket 022: markdown Detail
/// navigation, plugin Argument input, and the loading/error status rows an async
/// plugin row source produces. These are the palette's testable seams; the
/// SwiftUI Detail/markdown rendering is view-internal and untested per repo
/// convention.
final class CommandPalettePluginStateTests: XCTestCase {

    /// A synchronous stand-in for a plugin row source with a configurable load
    /// state, so the state's section assembly is exercised without the runtime.
    @MainActor
    private final class StubRowSource: PluginRowSource {
        let id: String
        let sectionTitleKey: String
        var stubLoadState: PluginRowLoadState
        private let stubRows: [PluginRowDescriptor]
        private(set) var performed: [(id: String, argument: String?)] = []

        init(
            id: String,
            sectionTitleKey: String,
            loadState: PluginRowLoadState,
            rows: [PluginRowDescriptor]
        ) {
            self.id = id
            self.sectionTitleKey = sectionTitleKey
            self.stubLoadState = loadState
            self.stubRows = rows
        }

        var loadState: PluginRowLoadState { stubLoadState }
        func rows() -> [PluginRowDescriptor] { stubRows }
        func performRow(id: String) async { performed.append((id, nil)) }
        func performRow(id: String, argument: String) async { performed.append((id, argument)) }
    }

    @MainActor
    private func registration(
        _ source: StubRowSource
    ) -> CommandPaletteExtensions.RowSourceRegistration {
        CommandPaletteExtensions.RowSourceRegistration(
            key: PluginRowSourceKey(
                pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
                localID: source.id
            ),
            sectionTitleKey: source.sectionTitleKey,
            source: source
        )
    }

    private let sourceKey = PluginRowSourceKey(
        pluginID: NativePluginID(rawValue: "script:com.acme.posts"),
        localID: "rows"
    )

    // MARK: - Detail navigation

    @MainActor
    func testEnterDetailStartsLoadingThenLoads() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 3

        state.enterDetail(title: "Latest Post")

        XCTAssertTrue(state.isInDetail)
        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.detailState, .loading(title: "Latest Post"))
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertTrue(state.flatEntries.isEmpty)

        state.updateDetail(.loaded(title: "Latest Post", markdown: "# Hello"))
        XCTAssertEqual(state.detailState, .loaded(title: "Latest Post", markdown: "# Hello"))
    }

    @MainActor
    func testDetailEscapeClearsQueryThenPopsToRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterDetail(title: "Post")
        state.updateDetail(.loaded(title: "Post", markdown: "body"))

        // A non-empty query clears first (even in Detail), then an empty query
        // pops back to root — the extended escape policy.
        state.query = "typed"
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertTrue(state.isInDetail)

        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testUpdateDetailIgnoredAfterNavigatingAway() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterDetail(title: "Post")
        state.popToRoot()

        // A late async markdown result must not resurrect a dismissed Detail.
        state.updateDetail(.loaded(title: "Post", markdown: "body"))
        XCTAssertTrue(state.isAtRoot)
        XCTAssertNil(state.detailState)
    }

    @MainActor
    func testDetailPopClearsMarkdownFailureState() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterDetail(title: "Post")
        state.updateDetail(.failed(title: "Post", message: "boom"))
        XCTAssertEqual(state.detailState, .failed(title: "Post", message: "boom"))
        state.popToRoot()
        XCTAssertNil(state.detailState)
    }

    // MARK: - Plugin Argument input

    @MainActor
    func testEnterPluginArgumentInputBadgesTitleAndClearsQuery() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 2

        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "search", title: "Search")

        XCTAssertTrue(state.isInArgumentInput)
        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.argumentInputTitle, "Search")
        XCTAssertEqual(state.argumentBadge, "Search")
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertTrue(state.flatEntries.isEmpty)
    }

    @MainActor
    func testPluginArgumentInputSynthesizesRunArgumentRow() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "search", title: "Search")

        state.query = "  anydoor  "
        let entry = try XCTUnwrap(state.commitSelection())
        guard case .pluginRow(let key, let descriptor) = entry.source else {
            return XCTFail("Expected a synthesized plugin row")
        }
        XCTAssertEqual(key, sourceKey)
        XCTAssertEqual(descriptor.id, "search")
        XCTAssertEqual(descriptor.title, "Search — anydoor")
        XCTAssertEqual(descriptor.commit, .runArgument("anydoor"))

        // Committing routes to the run-argument intent, carrying the trimmed text.
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(entry.source),
            .pluginRowRunArgument(sourceKey: sourceKey, rowID: "search", argument: "anydoor")
        )
    }

    @MainActor
    func testPluginArgumentInputEmptyQueryHasNoCommittableRow() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "search", title: "Search")
        state.query = "   "
        XCTAssertNil(state.commitSelection())
        XCTAssertTrue(state.flatEntries.isEmpty)
    }

    @MainActor
    func testPluginArgumentEscapeClearsThenPops() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "search", title: "Search")
        state.query = "anydoor"

        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertTrue(state.isInArgumentInput)
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)
    }

    // MARK: - Loading / error status rows

    @MainActor
    func testLoadingSourceShowsSingleNonInteractiveStatusRow() throws {
        let source = StubRowSource(
            id: "rows", sectionTitleKey: "commandPalette.section.hosts",
            loadState: .loading, rows: []
        )
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [registration(source)])
        state.query = "anything"

        XCTAssertEqual(state.filteredSections.map(\.titleKey), ["commandPalette.section.hosts"])
        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(state.flatEntries.count, 1)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a plugin status row")
        }
        XCTAssertEqual(descriptor.symbol, "hourglass")
        XCTAssertEqual(descriptor.commit, .noAction)
        // A loading row commits to nothing — the palette neither closes nor hangs.
        XCTAssertEqual(CommandPaletteCommitIntent.classify(entry.source), .noAction)
    }

    @MainActor
    func testFailedSourceShowsInlineErrorRowCarryingMessage() throws {
        let source = StubRowSource(
            id: "rows", sectionTitleKey: "commandPalette.section.hosts",
            loadState: .failed("network is down"), rows: []
        )
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [registration(source)])
        state.query = "anything"

        let entry = try XCTUnwrap(state.flatEntries.first)
        XCTAssertEqual(state.flatEntries.count, 1)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a plugin error row")
        }
        XCTAssertEqual(descriptor.symbol, "exclamationmark.triangle")
        XCTAssertEqual(descriptor.title, "network is down")
        XCTAssertEqual(descriptor.commit, .noAction)
    }

    @MainActor
    func testReadySourceShowsRealRowsFilteredByQuery() throws {
        let source = StubRowSource(
            id: "rows", sectionTitleKey: "commandPalette.section.hosts",
            loadState: .ready,
            rows: [
                PluginRowDescriptor(id: "a", title: "Alpha", symbol: "star", commit: .pushDetail),
                PluginRowDescriptor(id: "b", title: "Beta", symbol: "star", commit: .closeThenAct),
            ]
        )
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [registration(source)])
        state.query = "alph"

        XCTAssertEqual(state.flatEntries.count, 1)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a real plugin row")
        }
        XCTAssertEqual(descriptor.id, "a")
        XCTAssertEqual(descriptor.commit, .pushDetail)
    }

    @MainActor
    func testStatusRowsAbsentWithoutAQuery() {
        let source = StubRowSource(
            id: "rows", sectionTitleKey: "commandPalette.section.hosts",
            loadState: .loading, rows: []
        )
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [registration(source)])
        // Plugin rows (status rows included) are query-gated like every other
        // plugin row source, so an empty query shows nothing.
        XCTAssertTrue(state.filteredSections.isEmpty)
    }
}
