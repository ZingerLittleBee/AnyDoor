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

        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Latest Post")

        XCTAssertTrue(state.isInDetail)
        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.detailState, .loading(title: "Latest Post"))
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)
        XCTAssertTrue(state.flatEntries.isEmpty)

        state.updateDetail(.loaded(title: "Latest Post", markdown: "# Hello"), generation: generation)
        XCTAssertEqual(state.detailState, .loaded(title: "Latest Post", markdown: "# Hello"))
    }

    @MainActor
    func testDetailEscapeClearsQueryThenPopsToRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        state.updateDetail(.loaded(title: "Post", markdown: "body"), generation: generation)

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
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        state.popToRoot()

        // A late async markdown result must not resurrect a dismissed Detail.
        state.updateDetail(.loaded(title: "Post", markdown: "body"), generation: generation)
        XCTAssertTrue(state.isAtRoot)
        XCTAssertNil(state.detailState)
    }

    @MainActor
    func testLateDetailResultDoesNotRepopulateALaterDrillIn() {
        // A→back→B: a slow Detail A result must not land on Detail B (their
        // plugin queues are independent, so A can resolve after B). The
        // generation token keys each result to the exact drill-in that asked.
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let genA = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post A")
        state.popToRoot()
        let genB = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post B")

        // A's slow result arrives now — ignored, B stays loading.
        state.updateDetail(.loaded(title: "Post A", markdown: "A body"), generation: genA)
        XCTAssertEqual(state.detailState, .loading(title: "Post B"))

        // B's own result applies.
        state.updateDetail(.loaded(title: "Post B", markdown: "B body"), generation: genB)
        XCTAssertEqual(state.detailState, .loaded(title: "Post B", markdown: "B body"))
        XCTAssertNotEqual(genA, genB)
    }

    @MainActor
    func testDetailPopClearsMarkdownFailureState() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        state.updateDetail(.failed(title: "Post", message: "boom"), generation: generation)
        XCTAssertEqual(state.detailState, .failed(title: "Post", message: "boom"))
        state.popToRoot()
        XCTAssertNil(state.detailState)
    }

    // MARK: - Detail load-more (comment pagination)

    @MainActor
    func testDetailMoreCursorFlowsFromLoadThroughAppendToEnd() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        XCTAssertNil(state.detailMoreCursor, "a loading Detail offers no sentinel")

        state.updateDetail(.loaded(title: "Post", markdown: "body"), more: "2", generation: generation)
        XCTAssertEqual(state.detailMoreCursor, "2")

        // Claiming the fetch marks it in flight; a second sentinel fire is refused.
        let request = state.beginDetailMore()
        XCTAssertEqual(request?.sourceKey, sourceKey)
        XCTAssertEqual(request?.rowID, "row")
        XCTAssertEqual(request?.cursor, "2")
        XCTAssertNil(state.beginDetailMore(), "one fetch in flight at a time")

        // The chunk appends below the document and adopts the next cursor.
        state.appendDetailChunk("page 2", more: "3", generation: request!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "Post", markdown: "body\n\npage 2"))
        XCTAssertEqual(state.detailMoreCursor, "3")

        // The final chunk carries no cursor: pagination ends, sentinel gone.
        let last = state.beginDetailMore()
        state.appendDetailChunk("page 3", more: nil, generation: last!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "Post", markdown: "body\n\npage 2\n\npage 3"))
        XCTAssertNil(state.detailMoreCursor)
        XCTAssertNil(state.beginDetailMore())
    }

    @MainActor
    func testEmptyChunkOnlyAdvancesCursorWithoutJunkSeparators() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        state.updateDetail(.loaded(title: "Post", markdown: "body"), more: "2", generation: generation)

        // A source whose last page came back empty terminates cleanly.
        let request = state.beginDetailMore()
        state.appendDetailChunk("  \n", more: nil, generation: request!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "Post", markdown: "body"))
        XCTAssertNil(state.detailMoreCursor)
    }

    @MainActor
    func testLateChunkDoesNotLandOnALaterDrillIn() {
        // Detail A offers more → user backs out → Detail B: A's slow chunk must
        // neither append to B nor resurrect A's cursor.
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let genA = state.enterDetail(sourceKey: sourceKey, rowID: "a", title: "A")
        state.updateDetail(.loaded(title: "A", markdown: "A body"), more: "2", generation: genA)
        let requestA = state.beginDetailMore()
        state.popToRoot()

        let genB = state.enterDetail(sourceKey: sourceKey, rowID: "b", title: "B")
        state.updateDetail(.loaded(title: "B", markdown: "B body"), generation: genB)

        state.appendDetailChunk("A page 2", more: "3", generation: requestA!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "B", markdown: "B body"))
        XCTAssertNil(state.detailMoreCursor)
    }

    @MainActor
    func testFailedLoadMoreStopsPaginationButKeepsDocument() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        state.updateDetail(.loaded(title: "Post", markdown: "body"), more: "2", generation: generation)

        let request = state.beginDetailMore()
        state.failDetailMore(generation: request!.generation)

        XCTAssertEqual(state.detailState, .loaded(title: "Post", markdown: "body"))
        XCTAssertNil(state.detailMoreCursor, "a broken source stops paginating silently")
        XCTAssertNil(state.beginDetailMore())
    }

    // MARK: - Detail footer actions

    @MainActor
    func testDetailActionRebuildFlowsThroughLoadingBackToLoaded() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Post")
        XCTAssertTrue(state.detailActions.isEmpty, "a loading Detail shows no action bar")

        state.updateDetail(
            .loaded(title: "Post", markdown: "original"),
            actions: [PluginRowDetailAction(id: "translate", label: "翻译")],
            generation: generation)
        XCTAssertEqual(state.detailActions.map(\.id), ["translate"])

        // Claiming the rebuild drops to loading (bar hidden), refusing a second press.
        let request = state.beginDetailAction()
        XCTAssertEqual(request?.sourceKey, sourceKey)
        XCTAssertEqual(request?.rowID, "row")
        XCTAssertEqual(state.detailState, .loading(title: "Post"))
        XCTAssertTrue(state.detailActions.isEmpty)
        XCTAssertNil(state.beginDetailAction(), "no second rebuild while one is in flight")

        // The rebuilt document replaces content, cursor, and actions wholesale.
        state.updateDetail(
            .loaded(title: "Post", markdown: "translated"),
            more: "t:2",
            actions: [PluginRowDetailAction(id: "original", label: "显示原文")],
            generation: request!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "Post", markdown: "translated"))
        XCTAssertEqual(state.detailMoreCursor, "t:2")
        XCTAssertEqual(state.detailActions.map(\.id), ["original"])
    }

    @MainActor
    func testLateDetailActionResultDoesNotLandOnALaterDrillIn() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let genA = state.enterDetail(sourceKey: sourceKey, rowID: "a", title: "A")
        state.updateDetail(
            .loaded(title: "A", markdown: "A body"),
            actions: [PluginRowDetailAction(id: "translate", label: "翻译")],
            generation: genA)
        let requestA = state.beginDetailAction()
        state.popToRoot()

        let genB = state.enterDetail(sourceKey: sourceKey, rowID: "b", title: "B")
        state.updateDetail(.loaded(title: "B", markdown: "B body"), generation: genB)

        // A's slow rebuild arrives now — the generation token discards it.
        state.updateDetail(
            .loaded(title: "A", markdown: "A translated"),
            generation: requestA!.generation)
        XCTAssertEqual(state.detailState, .loaded(title: "B", markdown: "B body"))
    }

    // MARK: - Plugin list navigation

    @MainActor
    func testEnterListStartsLoadingAndResetsQuery() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "stale"
        state.selectedIndex = 4

        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot Topics")

        XCTAssertTrue(state.isInList)
        XCTAssertFalse(state.isAtRoot)
        XCTAssertEqual(state.listLevel?.title, "Hot Topics")
        XCTAssertEqual(state.listLevel?.listID, "hot")
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.selectedIndex, 0)

        // A loading list shows a single non-interactive status row.
        XCTAssertEqual(state.flatEntries.count, 1)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a plugin status row")
        }
        XCTAssertEqual(descriptor.symbol, "hourglass")
        XCTAssertEqual(descriptor.commit, .noAction)

        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)
        XCTAssertEqual(state.flatEntries.count, 1)
    }

    @MainActor
    func testLoadedListFiltersByQueryAndKeepsRowSemantics() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", subtitle: "swift", symbol: "doc", commit: .pushDetail),
            PluginRowDescriptor(id: "2", title: "Beta", symbol: "doc", commit: .openURL("https://x.dev")),
        ]), generation: generation)

        // Empty query shows all rows (like the options level).
        XCTAssertEqual(state.flatEntries.count, 2)

        state.query = "alph"
        XCTAssertEqual(state.flatEntries.count, 1)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a real plugin row")
        }
        XCTAssertEqual(descriptor.id, "1")
        // A list row keeps its own declared commit — a Detail push from within a list.
        XCTAssertEqual(
            CommandPaletteCommitIntent.classify(entry.source),
            .pluginRowPushDetail(sourceKey: sourceKey, rowID: "1", title: "Alpha")
        )
    }

    @MainActor
    func testFailedListShowsInlineErrorRowCarryingMessage() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        state.updateList(.failed("network is down"), generation: generation)

        XCTAssertEqual(state.flatEntries.count, 1)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .pluginRow(_, let descriptor) = entry.source else {
            return XCTFail("Expected a plugin error row")
        }
        XCTAssertEqual(descriptor.symbol, "exclamationmark.triangle")
        XCTAssertEqual(descriptor.title, "network is down")
        XCTAssertEqual(descriptor.commit, .noAction)
    }

    @MainActor
    func testUpdateListIgnoredAfterPopToRoot() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        state.popToRoot()

        // A late async list result must not resurrect a discarded drill-in.
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)
        XCTAssertTrue(state.isAtRoot)
        XCTAssertNil(state.listLevel)
    }

    @MainActor
    func testLateListResultDoesNotRepopulateALaterDrillIn() {
        // list A -> back -> list B: a slow A result must not land on B (their
        // plugin queues are independent). The generation token keys each result.
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let genA = state.enterList(sourceKey: sourceKey, listID: "hot", title: "A")
        state.popToRoot()
        let genB = state.enterList(sourceKey: sourceKey, listID: "latest", title: "B")

        state.updateList(.loaded([
            PluginRowDescriptor(id: "x", title: "A row", symbol: "doc", commit: .pushDetail),
        ]), generation: genA)
        XCTAssertEqual(state.listLevel?.content, .loading, "B stays loading; A's late result is ignored")

        state.updateList(.loaded([
            PluginRowDescriptor(id: "y", title: "B row", symbol: "doc", commit: .pushDetail),
        ]), generation: genB)
        XCTAssertEqual(state.listLevel?.content, .loaded([
            PluginRowDescriptor(id: "y", title: "B row", symbol: "doc", commit: .pushDetail),
        ]))
        XCTAssertNotEqual(genA, genB)
    }

    @MainActor
    func testEscapePopsRootListDetailListRootOneLevelAtATime() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        // root -> list
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)
        XCTAssertTrue(state.isInList)

        // list -> detail (drilled from a list row)
        state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Alpha")
        XCTAssertTrue(state.isInDetail)

        // Esc pops the Detail back to the LIST it came from, not the root.
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isInList)
        XCTAssertEqual(state.listLevel?.title, "Hot")
        // The list's cached rows survive the round trip (no refetch needed).
        XCTAssertEqual(state.flatEntries.count, 1)

        // Esc again pops the list to the root.
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)

        // Esc at the root dismisses.
        XCTAssertEqual(state.handleEscape(), .dismiss)
    }

    @MainActor
    func testEscapeInListClearsQueryBeforePopping() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)

        state.query = "typed"
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertTrue(state.isInList, "a non-empty query clears first, staying in the list")
        XCTAssertEqual(state.query, "")

        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isAtRoot)
    }

    @MainActor
    func testArgumentInputDrilledFromListPopsBackToList() {
        // A list row can declare `.enterArgument`; escaping the argument input
        // returns to the list, not the root (the stack restores the level below).
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "nodes", title: "Nodes")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "set", title: "Set Node", symbol: "gear", commit: .enterArgument),
        ]), generation: generation)

        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "set", title: "Set Node")
        XCTAssertTrue(state.isInArgumentInput)

        state.query = "swift"
        XCTAssertEqual(state.handleEscape(), .clearedQuery)
        XCTAssertEqual(state.handleEscape(), .poppedToRoot)
        XCTAssertTrue(state.isInList)
        XCTAssertEqual(state.listLevel?.title, "Nodes")
    }

    @MainActor
    func testNavigationRevisionAdvancesOnEveryTransitionNotOnContentUpdates() {
        // The view watches `navigationRevision` to re-anchor the overlaid AppKit
        // search field after a level shifts (a back header appears/disappears).
        // Every push/pop must bump it; a content update (list rows resolving)
        // must not, since the field's slot has not moved.
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        var revisions: [Int] = [state.navigationRevision]
        func note() { revisions.append(state.navigationRevision) }

        // root -> list
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "Hot")
        note()
        // A content update alone must NOT advance the revision.
        let before = state.navigationRevision
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Alpha", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)
        XCTAssertEqual(state.navigationRevision, before, "resolving list rows does not move the field")

        // list -> detail -> list -> root -> (argument in -> out)
        state.enterDetail(sourceKey: sourceKey, rowID: "row", title: "Alpha"); note()
        state.popLevel(); note()          // detail -> list
        state.popLevel(); note()          // list -> root
        state.enterPluginArgumentInput(sourceKey: sourceKey, rowID: "s", title: "S"); note()
        state.popLevel(); note()          // argument -> root

        // Strictly increasing across every transition.
        for (earlier, later) in zip(revisions, revisions.dropFirst()) {
            XCTAssertLessThan(earlier, later, "each level transition bumps the navigation revision")
        }
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

    // MARK: - Root plugin-row filtering (pure seam)

    private static let v2exRows = [
        PluginRowDescriptor(id: "hot", title: "热门主题", subtitle: "Hot topics", symbol: "flame", commit: .pushList("hot")),
        PluginRowDescriptor(id: "latest", title: "最新主题", subtitle: "Latest topics", symbol: "clock", commit: .pushList("latest")),
        PluginRowDescriptor(id: "node", title: "节点主题", symbol: "square.grid.2x2", commit: .pushList("node")),
        PluginRowDescriptor(id: "token", title: "设置 V2EX Token", symbol: "key", commit: .enterArgument),
    ]

    /// Typing the plugin's display name (the section title) surfaces every row,
    /// mirroring Raycast — even the three rows whose titles do not contain "v2".
    func testSectionTitleMatchSurfacesAllRows() {
        let filtered = CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "v2", sectionTitle: "V2EX"
        )
        XCTAssertEqual(filtered.map(\.id), ["hot", "latest", "node", "token"])
    }

    /// A section-title match is case-insensitive (the header is "V2EX").
    func testSectionTitleMatchIsCaseInsensitive() {
        let filtered = CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "V2ex", sectionTitle: "V2EX"
        )
        XCTAssertEqual(filtered.count, Self.v2exRows.count)
    }

    /// When the section title does not match, rows filter by their own title.
    func testRowTitleMatchNarrowsWithinSource() {
        let filtered = CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "热门", sectionTitle: "V2EX"
        )
        XCTAssertEqual(filtered.map(\.id), ["hot"])
    }

    /// A row is also kept when the query matches its subtitle (case-insensitive).
    func testRowSubtitleMatchNarrowsWithinSource() {
        let filtered = CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "hot", sectionTitle: "V2EX"
        )
        // "hot" matches only the "Hot topics" subtitle (no title/section match).
        XCTAssertEqual(filtered.map(\.id), ["hot"])
    }

    /// A query matching neither the section title nor any row still excludes all.
    func testNonMatchingQueryExcludesEveryRow() {
        let filtered = CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "nonesuch", sectionTitle: "V2EX"
        )
        XCTAssertTrue(filtered.isEmpty)
    }

    /// An empty (or whitespace-only) query yields nothing — plugin rows are
    /// query-gated at the root.
    func testEmptyQueryYieldsNoRows() {
        XCTAssertTrue(CommandPaletteState.filterRootPluginRows(
            Self.v2exRows, query: "   ", sectionTitle: "V2EX"
        ).isEmpty)
    }

    /// End-to-end through the state: a plain-string section title ("V2EX", how a
    /// Script Plugin registers) lists all four rows for "v2", proving the wiring
    /// resolves and matches the section header, not only row titles.
    @MainActor
    func testStateSurfacesAllRowsOnSectionTitleMatch() {
        let source = StubRowSource(
            id: "rows", sectionTitleKey: "V2EX", loadState: .ready, rows: Self.v2exRows
        )
        let state = CommandPaletteState(sections: [], hyperFlags: 0, rowSources: [registration(source)])
        state.query = "v2"
        XCTAssertEqual(state.flatEntries.count, 4)
    }

    // MARK: - List-level plugin-row filtering (title + subtitle, no section)

    /// Inside a pushed list, a subtitle match keeps the row (the section title is
    /// not consulted — the plugin context is already chosen).
    func testPluginRowMatchesTitleOrSubtitle() {
        let row = PluginRowDescriptor(
            id: "1", title: "Alpha", subtitle: "swift topic", symbol: "doc", commit: .pushDetail
        )
        XCTAssertTrue(CommandPaletteState.pluginRowMatches(row, query: "alph"))
        XCTAssertTrue(CommandPaletteState.pluginRowMatches(row, query: "SWIFT"))
        XCTAssertFalse(CommandPaletteState.pluginRowMatches(row, query: "beta"))
    }

    /// The pushed-list level matches title AND subtitle but never the section
    /// title: "v2" (the plugin name) filters rows down to those whose own text
    /// contains it, not all rows.
    @MainActor
    func testListLevelMatchesRowTextNotSectionTitle() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        let generation = state.enterList(sourceKey: sourceKey, listID: "hot", title: "V2EX")
        state.updateList(.loaded([
            PluginRowDescriptor(id: "1", title: "Rust on V2EX", symbol: "doc", commit: .pushDetail),
            PluginRowDescriptor(id: "2", title: "Swift thread", subtitle: "about v2ex api", symbol: "doc", commit: .pushDetail),
            PluginRowDescriptor(id: "3", title: "Unrelated", symbol: "doc", commit: .pushDetail),
        ]), generation: generation)

        state.query = "v2ex"
        // Row 1 (title) and row 2 (subtitle) match; row 3 does not — the section
        // title "V2EX" is not consulted at this level.
        XCTAssertEqual(state.flatEntries.count, 2)
    }
}
