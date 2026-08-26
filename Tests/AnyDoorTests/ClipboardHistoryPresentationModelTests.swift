import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPresentationModelTests: XCTestCase {
    func testInitialLoadPublishesFirstPageAndSelectsNewestEntry() async {
        let first = entry(1)
        let second = entry(2)
        let cursor = ClipboardHistoryCursor(token: Data("next".utf8))
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [first, second],
                    nextCursor: cursor,
                    cursorDisposition: .initial
                )
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)

        await model.load()

        XCTAssertEqual(model.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.contentState, .content)
        XCTAssertEqual(model.pagingState, .moreAvailable)
        let requests = await client.pageRequests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].query, ClipboardHistoryQuery())
        XCTAssertNil(requests[0].cursor)
    }

    func testNearEndPrefetchAppendsNextPageOnce() async {
        let firstPage = (0..<100).map(entry)
        let next = entry(100)
        let cursor = ClipboardHistoryCursor(token: Data("next".utf8))
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: cursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [next],
                    nextCursor: nil,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.load()

        await model.prefetchIfNeeded(visibleID: firstPage[94].id)
        await model.prefetchIfNeeded(visibleID: firstPage[99].id)

        XCTAssertEqual(model.entries.count, 101)
        XCTAssertEqual(model.entries.last?.id, next.id)
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.pageRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].cursor, cursor)
    }

    func testChangingQueryAndFiltersInvalidatesCursor() async {
        let cursor = ClipboardHistoryCursor(token: Data("next".utf8))
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [entry(0)],
                    nextCursor: cursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [entry(1)],
                    nextCursor: cursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [entry(2)],
                    nextCursor: nil,
                    cursorDisposition: .initial
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.load()

        await model.setQuery(
            ClipboardHistoryQuery(text: "needle")
        )
        await model.setQuery(
            ClipboardHistoryQuery(
                text: "needle",
                facet: .image,
                sourceID: .application("com.example.Source"),
                tagID: "work",
                favoritesOnly: true
            )
        )

        let requests = await client.pageRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(requests[1].cursor)
        XCTAssertNil(requests[2].cursor)
        XCTAssertEqual(requests[1].query.text, "needle")
        XCTAssertEqual(requests[2].query.facet, .image)
        XCTAssertEqual(
            requests[2].query.sourceID,
            .application("com.example.Source")
        )
        XCTAssertEqual(requests[2].query.tagID, "work")
        XCTAssertTrue(requests[2].query.favoritesOnly)
    }

    func testReloadPreservesSelectionWhenEntryStillExists() async {
        let selected = entry(1)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [entry(0), selected],
                    nextCursor: nil,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [entry(2), selected],
                    nextCursor: nil,
                    cursorDisposition: .initial
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.load()
        model.select(selected.id)

        await model.reload()

        XCTAssertEqual(model.selectedID, selected.id)
    }

    func testEmptyIndexingUnavailableAndActionFailureAreDistinctStates() async {
        let unavailable = ClipboardHistoryStatus(
            availability: .unavailable,
            reason: .missingKey,
            isMonitoring: false
        )
        let unavailableClient = PresentationClientStub(
            status: unavailable,
            pages: []
        )
        let unavailableModel = ClipboardHistoryPresentationModel(
            operations: unavailableClient.operations
        )
        await unavailableModel.load()
        XCTAssertEqual(
            unavailableModel.contentState,
            .unavailable(.missingKey)
        )

        let indexingClient = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: .initial,
                    state: .indexing
                )
            ]
        )
        let indexingModel = ClipboardHistoryPresentationModel(
            operations: indexingClient.operations
        )
        await indexingModel.load()
        XCTAssertEqual(indexingModel.contentState, .indexing)

        let emptyClient = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            ],
            applyError: ClipboardHistoryModuleError.storageFailure
        )
        let emptyModel = ClipboardHistoryPresentationModel(
            operations: emptyClient.operations
        )
        await emptyModel.load()
        XCTAssertEqual(emptyModel.contentState, .empty)

        await emptyModel.apply(.delete(entry(9).id))
        XCTAssertEqual(emptyModel.contentState, .empty)
        XCTAssertEqual(emptyModel.actionFailure, .storageFailure)
    }

    func testPlainTextOfferRequiresExactTextOnEveryItem() async {
        let id = entry(20).id
        let exact = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: "first"
                        ),
                        .data(
                            typeIdentifier: "public.rtf",
                            Data([0x01])
                        ),
                    ]
                ),
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(
                            typeIdentifier: "public.utf8-plain-text",
                            value: "second"
                        )
                    ]
                ),
            ]
        )
        let exactModel = materializationModel(returning: exact)

        _ = await exactModel.materialization(
            for: id,
            purpose: .hostAction
        )

        XCTAssertTrue(exactModel.supportsPlainTextPaste(for: id))

        let mixed = ClipboardHistoryMaterialization(
            items: exact.items + [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .data(
                            typeIdentifier: "public.png",
                            Data([0x89, 0x50])
                        )
                    ]
                )
            ]
        )
        let mixedModel = materializationModel(returning: mixed)

        _ = await mixedModel.materialization(
            for: id,
            purpose: .hostAction
        )

        XCTAssertFalse(mixedModel.supportsPlainTextPaste(for: id))
    }

    func testSourceCatalogDoesNotCollapseWhileSourceFilterIsActive() async {
        let sourcedEntry = ClipboardHistoryEntry(
            id: ClipboardHistoryEntryID(UUID()),
            capturedAt: Date(),
            previewText: "Safari",
            facets: [.text],
            isFavorite: false,
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: "com.apple.Safari",
                displayName: "Safari"
            )
        )
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [sourcedEntry],
                    nextCursor: nil,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: .initial
                ),
            ],
            sourceSummaries: [
                ClipboardHistorySourceSummary(
                    bundleIdentifier: "com.apple.Safari",
                    displayName: "Safari",
                    count: 1
                )
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        await model.setQuery(
            ClipboardHistoryQuery(
                sourceID: .application("com.example.Empty")
            )
        )

        XCTAssertEqual(
            model.sources,
            [
                ClipboardHistoryPresentationSource(
                    id: .application("com.apple.Safari"),
                    bundleID: "com.apple.Safari",
                    name: "Safari",
                    count: 1
                )
            ]
        )
        XCTAssertEqual(model.contentState, .empty)
    }

    func testTagDefinitionOperationsPublishOnlyAuthoritativeOutcomes() async {
        let original = entry(30)
        let originalTag = ClipboardHistoryTagDefinition(
            id: "work",
            displayName: "Work"
        )
        let client = TagPresentationClient(
            entry: original,
            tags: [originalTag]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        let didCreate = await model.createTagDefinition(
            named: "Project",
            assigningTo: original.id
        )
        XCTAssertTrue(didCreate)
        let project = ClipboardHistoryTagDefinition(
            id: "project",
            displayName: "Project"
        )
        XCTAssertEqual(model.tags, [originalTag, project])
        XCTAssertEqual(model.entries.first?.tagIDs, ["project"])

        let didRename = await model.renameTagDefinition(
            id: "project",
            to: "Focused"
        )
        XCTAssertTrue(didRename)
        XCTAssertEqual(
            model.tags,
            [
                originalTag,
                ClipboardHistoryTagDefinition(
                    id: "project",
                    displayName: "Focused"
                ),
            ]
        )

        let didDelete = await model.deleteTagDefinition(id: "project")
        XCTAssertTrue(didDelete)
        XCTAssertEqual(model.tags, [originalTag])
        XCTAssertEqual(model.entries.first?.tagIDs, [])
        XCTAssertNil(model.actionFailure)
    }

    func testTagDefinitionFailureCannotDriftPublishedState() async {
        let original = entry(31)
        let tag = ClipboardHistoryTagDefinition(
            id: "work",
            displayName: "Work"
        )
        let client = TagPresentationClient(
            entry: original,
            tags: [tag],
            failure: .storageFailure
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        let didCreate = await model.createTagDefinition(
            named: "Project",
            assigningTo: original.id
        )
        XCTAssertFalse(didCreate)

        XCTAssertEqual(model.tags, [tag])
        XCTAssertEqual(model.entries, [original])
        XCTAssertEqual(model.actionFailure, .storageFailure)
    }

    func testChangingTextCancelsSuspendedInitialPageAndDiscardsIt()
        async
    {
        let stale = entry(40)
        let replacement = entry(41)
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial Clipboard page request") {
            await client.requestCount == 1
        }
        let replacementLoad = Task {
            await model.setQuery(ClipboardHistoryQuery(text: "needle"))
        }
        await waitUntil("replacement Clipboard page request") {
            await client.requestCount == 2
        }
        await waitUntil("initial Clipboard request cancellation") {
            await client.cancelledRequestIDs == [0]
        }

        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [replacement],
                nextCursor: nil,
                cursorDisposition: .initial
            )
        )
        await replacementLoad.value
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: [stale],
                nextCursor: ClipboardHistoryCursor(
                    token: Data("stale".utf8)
                ),
                cursorDisposition: .initial,
                state: .failed(.rebuildFailed)
            )
        )
        await initialLoad.value

        XCTAssertEqual(model.entries, [replacement])
        XCTAssertEqual(model.query.text, "needle")
        XCTAssertEqual(model.pagingState, .complete)
        XCTAssertNil(model.actionFailure)
        let requests = await client.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, nil])
    }

    func testChangingEachFilterDiscardsSuspendedInitialPage() async {
        let filters = [
            ClipboardHistoryQuery(facet: .image),
            ClipboardHistoryQuery(
                sourceID: .application("com.example.Source")
            ),
            ClipboardHistoryQuery(tagID: "work"),
            ClipboardHistoryQuery(favoritesOnly: true),
            ClipboardHistoryQuery(
                capturedAfter: Date(timeIntervalSince1970: 100)
            ),
            ClipboardHistoryQuery(
                capturedBefore: Date(timeIntervalSince1970: 200)
            ),
        ]

        for (index, filter) in filters.enumerated() {
            let client = ControlledPresentationClient()
            let model = ClipboardHistoryPresentationModel(
                operations: client.operations
            )
            let initialLoad = Task { await model.load() }
            await waitUntil("initial filter page request \(index)") {
                await client.requestCount == 1
            }
            let replacementLoad = Task {
                await model.setQuery(filter)
            }
            await waitUntil("replacement filter page request \(index)") {
                await client.requestCount == 2
            }

            let replacement = entry(50 + index)
            await client.release(
                requestID: 1,
                page: ClipboardHistoryPage(
                    entries: [replacement],
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            )
            await replacementLoad.value
            await client.release(
                requestID: 0,
                page: ClipboardHistoryPage(
                    entries: [entry(60 + index)],
                    nextCursor: ClipboardHistoryCursor(
                        token: Data("stale-\(index)".utf8)
                    ),
                    cursorDisposition: .initial
                )
            )
            await initialLoad.value

            XCTAssertEqual(model.query, filter)
            XCTAssertEqual(model.entries, [replacement])
            XCTAssertEqual(model.pagingState, .complete)
            XCTAssertNil(model.actionFailure)
            let requests = await client.requests
            XCTAssertEqual(requests.map(\.cursor), [nil, nil])
        }
    }

    func testQueryChangeCancelsSingleFlightPrefetchAndCleansItUp()
        async
    {
        let firstPage = (0..<100).map(entry)
        let stale = entry(100)
        let replacement = entry(101)
        let final = entry(102)
        let firstCursor = ClipboardHistoryCursor(
            token: Data("first".utf8)
        )
        let replacementCursor = ClipboardHistoryCursor(
            token: Data("replacement".utf8)
        )
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: firstPage,
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value

        let stalePrefetch = Task {
            await model.prefetchIfNeeded(visibleID: firstPage[94].id)
        }
        await waitUntil("prefetch page request") {
            await client.requestCount == 2
        }
        await model.prefetchIfNeeded(visibleID: firstPage[99].id)
        let requestCountDuringPrefetch = await client.requestCount
        XCTAssertEqual(requestCountDuringPrefetch, 2)

        let replacementLoad = Task {
            await model.setQuery(ClipboardHistoryQuery(text: "new"))
        }
        await waitUntil("replacement query page request") {
            await client.requestCount == 3
        }
        await waitUntil("stale prefetch cancellation") {
            await client.cancelledRequestIDs.contains(1)
        }
        await client.release(
            requestID: 2,
            page: ClipboardHistoryPage(
                entries: [replacement],
                nextCursor: replacementCursor,
                cursorDisposition: .initial
            )
        )
        await replacementLoad.value
        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [stale],
                nextCursor: ClipboardHistoryCursor(
                    token: Data("stale-next".utf8)
                ),
                cursorDisposition: .continued,
                state: .failed(.stateUnavailable)
            )
        )
        await stalePrefetch.value

        XCTAssertEqual(model.entries, [replacement])
        XCTAssertEqual(model.pagingState, .moreAvailable)
        XCTAssertNil(model.actionFailure)

        let replacementPrefetch = Task {
            await model.prefetchIfNeeded(visibleID: replacement.id)
        }
        await waitUntil("replacement prefetch request") {
            await client.requestCount == 4
        }
        await client.release(
            requestID: 3,
            page: ClipboardHistoryPage(
                entries: [final],
                nextCursor: nil,
                cursorDisposition: .continued
            )
        )
        await replacementPrefetch.value

        XCTAssertEqual(model.entries, [replacement, final])
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.requests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, nil, replacementCursor]
        )
    }

    func testRefetchPolicyOnlyTriggersWhenQueryMembershipCanChange() {
        typealias Model = ClipboardHistoryPresentationModel
        let id = entry(0).id
        let unfiltered = ClipboardHistoryQuery()

        // A delete is always patched in place — the row leaves every view.
        XCTAssertFalse(
            Model.requiresRefetch(for: .delete(id), query: unfiltered)
        )
        XCTAssertFalse(
            Model.requiresRefetch(
                for: .delete(id),
                query: ClipboardHistoryQuery(favoritesOnly: true)
            )
        )

        // Content-only edits keep membership unless the query filters on
        // exactly the attribute that changed.
        XCTAssertFalse(
            Model.requiresRefetch(for: .setFavorite(id, false), query: unfiltered)
        )
        XCTAssertTrue(
            Model.requiresRefetch(
                for: .setFavorite(id, false),
                query: ClipboardHistoryQuery(favoritesOnly: true)
            )
        )
        XCTAssertFalse(
            Model.requiresRefetch(for: .setTags(id, []), query: unfiltered)
        )
        XCTAssertTrue(
            Model.requiresRefetch(
                for: .setTags(id, []),
                query: ClipboardHistoryQuery(tagID: "work")
            )
        )
        XCTAssertFalse(
            Model.requiresRefetch(for: .editText(id, "next"), query: unfiltered)
        )
        XCTAssertTrue(
            Model.requiresRefetch(
                for: .editText(id, "next"),
                query: ClipboardHistoryQuery(text: "needle")
            )
        )
    }

    func testDeletingDeepEntryKeepsLoadedPagesInsteadOfRefetching() async {
        let firstPage = (0..<100).map(entry)
        let second = entry(100)
        let cursor = ClipboardHistoryCursor(token: Data("next".utf8))
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: cursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [second],
                    nextCursor: nil,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        await model.prefetchIfNeeded(visibleID: firstPage[99].id)
        XCTAssertEqual(model.entries.count, 101)

        await model.apply(.delete(second.id))

        XCTAssertEqual(model.entries.count, 100)
        XCTAssertFalse(model.entries.contains { $0.id == second.id })
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.count,
            2,
            "a delete must patch the loaded pages, not snap back to page one"
        )
    }

    func testMaterializationCacheEvictsLeastRecentlyUsedEntries() async {
        let entries = (0..<40).map(entry)
        let counter = MaterializeCounter()
        let model = ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in
                    ClipboardHistoryPage(
                        entries: entries,
                        nextCursor: nil,
                        cursorDisposition: .initial
                    )
                },
                apply: { _ in .notFound },
                materialize: { request in
                    await counter.record(request.entryID)
                    return ClipboardHistoryMaterialization(items: [])
                },
                tagDefinitions: { [] }
            )
        )
        await model.load()

        for entry in entries.prefix(20) {
            _ = await model.materialization(for: entry.id, purpose: .preview)
        }

        // 20 previews against a 16-slot cache: the oldest were evicted and
        // have to be materialized again, the newest are still resident.
        XCTAssertNil(
            model.cachedMaterialization(for: entries[0].id, purpose: .preview)
        )
        XCTAssertNotNil(
            model.cachedMaterialization(for: entries[19].id, purpose: .preview)
        )

        _ = await model.materialization(for: entries[0].id, purpose: .preview)
        _ = await model.materialization(for: entries[19].id, purpose: .preview)

        let evicted = await counter.count(for: entries[0].id)
        let resident = await counter.count(for: entries[19].id)
        XCTAssertEqual(evicted, 2)
        XCTAssertEqual(resident, 1)
    }

    func testLoadNextPageAppendsDeduplicatesAndAdoptsTheReturnedCursor()
        async
    {
        let firstPage = (0..<3).map(entry)
        let overlap = firstPage[2]
        let third = entry(3)
        let fourth = entry(4)
        let firstCursor = cursor("first")
        let secondCursor = cursor("second")
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                // The module repeats the boundary row; it must not appear twice.
                ClipboardHistoryPage(
                    entries: [overlap, third],
                    nextCursor: secondCursor,
                    cursorDisposition: .continued
                ),
                ClipboardHistoryPage(
                    entries: [fourth],
                    nextCursor: nil,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        XCTAssertEqual(model.pagingState, .moreAvailable)

        await model.loadNextPage()

        XCTAssertEqual(
            model.entries.map(\.id),
            firstPage.map(\.id) + [third.id]
        )
        XCTAssertEqual(model.pagingState, .moreAvailable)

        await model.loadNextPage()

        XCTAssertEqual(
            model.entries.map(\.id),
            firstPage.map(\.id) + [third.id, fourth.id]
        )
        XCTAssertEqual(model.pagingState, .complete)

        // The chain ended, so there is nothing left to ask for.
        await model.loadNextPage()

        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, secondCursor]
        )
    }

    func testConcurrentLoadNextPageCallsIssueASingleFetch() async {
        let firstPage = (0..<3).map(entry)
        let next = entry(3)
        let firstCursor = cursor("first")
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: firstPage,
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value

        let inFlight = Task { await model.loadNextPage() }
        await waitUntil("load-more request") {
            await client.requestCount == 2
        }
        XCTAssertEqual(model.pagingState, .loading)

        // A key repeat, or a sentinel that reappears mid-fetch, must not
        // duplicate the request for the same cursor.
        await model.loadNextPage()
        let requestCountDuringFlight = await client.requestCount
        XCTAssertEqual(requestCountDuringFlight, 2)

        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [next],
                nextCursor: nil,
                cursorDisposition: .continued
            )
        )
        await inFlight.value

        XCTAssertEqual(model.entries.count, 4)
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, firstCursor])
    }

    func testPagingFailureIsRetryableAndNeverSetsActionFailure() async {
        let firstPage = (0..<3).map(entry)
        let recovered = entry(3)
        let firstCursor = cursor("first")
        let secondCursor = cursor("second")
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: .continued,
                    state: .failed(.stateUnavailable)
                ),
                ClipboardHistoryPage(
                    entries: [recovered],
                    nextCursor: secondCursor,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        model.select(firstPage[1].id)

        await model.loadNextPage()

        XCTAssertEqual(model.pagingState, .failed)
        XCTAssertEqual(model.entries.map(\.id), firstPage.map(\.id))
        XCTAssertEqual(model.selectedID, firstPage[1].id)
        XCTAssertEqual(model.contentState, .content)
        XCTAssertNil(model.actionFailure)

        await model.loadNextPage()

        XCTAssertEqual(model.pagingState, .moreAvailable)
        XCTAssertEqual(model.entries.last?.id, recovered.id)

        // The stub is out of pages, so this request throws.
        await model.loadNextPage()

        XCTAssertEqual(model.pagingState, .failed)
        XCTAssertEqual(model.entries.count, 4)
        XCTAssertNil(model.actionFailure)
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, firstCursor, secondCursor],
            "a failed page must retry from the same cursor, not skip it"
        )
    }

    func testTotalCountLandsWithTheFirstPageAndFailsWithoutDisturbingIt()
        async
    {
        let entries = (0..<3).map(entry)
        let counted = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: entries,
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            ],
            counts: [42]
        )
        let countedModel = ClipboardHistoryPresentationModel(
            operations: counted.operations
        )

        await countedModel.load()

        XCTAssertEqual(countedModel.totalCount, 42)
        XCTAssertEqual(countedModel.entries.count, 3)
        let countRequests = await counted.countRequests
        XCTAssertEqual(countRequests, [ClipboardHistoryQuery()])

        // A delete is patched in place and never refetches, so the total has to
        // follow the row out of the result set.
        await countedModel.apply(.delete(entries[0].id))
        XCTAssertEqual(countedModel.totalCount, 41)

        let uncounted = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: entries,
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            ]
        )
        let uncountedModel = ClipboardHistoryPresentationModel(
            operations: uncounted.operations
        )

        await uncountedModel.load()

        XCTAssertNil(uncountedModel.totalCount)
        XCTAssertEqual(uncountedModel.entries.map(\.id), entries.map(\.id))
        XCTAssertEqual(uncountedModel.contentState, .content)
        XCTAssertEqual(uncountedModel.pagingState, .complete)
        XCTAssertNil(
            uncountedModel.actionFailure,
            "a failed count may not surface as a destructive action failure"
        )
    }

    func testRestartedPageRebasesThePrefixInsteadOfAppendingIt() async {
        let original = (0..<4).map(entry)
        // The capture that bumped the index generation and invalidated the
        // cursor the wall was holding.
        let captured = entry(100)
        let deeper = entry(4)
        let firstCursor = cursor("first")
        let staleCursor = cursor("stale")
        let rebaseCursor = cursor("rebase-1")
        let secondRebaseCursor = cursor("rebase-2")
        let thirdRebaseCursor = cursor("rebase-3")
        let client = ControlledPresentationClient()
        await client.setCount(4)
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: Array(original[0..<2]),
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value
        XCTAssertEqual(model.totalCount, 4)

        let continuation = Task { await model.loadNextPage() }
        await waitUntil("second page request") {
            await client.requestCount == 2
        }
        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: Array(original[2..<4]),
                nextCursor: staleCursor,
                cursorDisposition: .continued
            )
        )
        await continuation.value
        model.select(original[2].id)
        XCTAssertEqual(model.entries.map(\.id), original.map(\.id))

        let rebase = Task { await model.loadNextPage() }
        await waitUntil("stale continuation request") {
            await client.requestCount == 3
        }
        await client.release(
            requestID: 2,
            page: ClipboardHistoryPage(
                entries: [captured, original[0]],
                nextCursor: rebaseCursor,
                cursorDisposition: .restarted
            )
        )
        await waitUntil("first rebase continuation request") {
            await client.requestCount == 4
        }

        // The restarted head is the newest slice of a *new* generation.
        // Appending it would put the newest entry at the oldest end, so nothing
        // may be published until the whole prefix has been rebuilt.
        XCTAssertEqual(model.entries.map(\.id), original.map(\.id))
        XCTAssertEqual(model.pagingState, .loading)

        await client.release(
            requestID: 3,
            page: ClipboardHistoryPage(
                entries: [original[1], original[2]],
                nextCursor: secondRebaseCursor,
                cursorDisposition: .continued
            )
        )
        await waitUntil("second rebase continuation request") {
            await client.requestCount == 5
        }
        XCTAssertEqual(model.entries.map(\.id), original.map(\.id))

        await client.setCount(6)
        await client.release(
            requestID: 4,
            page: ClipboardHistoryPage(
                entries: [original[3], deeper],
                nextCursor: thirdRebaseCursor,
                cursorDisposition: .continued
            )
        )
        await rebase.value

        XCTAssertEqual(
            model.entries.map(\.id),
            [captured.id] + original.map(\.id) + [deeper.id],
            "the rebased prefix has to stay newest-first and contiguous"
        )
        XCTAssertEqual(
            model.selectedID,
            original[2].id,
            "selection is reconciled by id across the generation change"
        )
        XCTAssertEqual(model.pagingState, .moreAvailable)
        XCTAssertEqual(
            model.totalCount,
            6,
            "the old total belongs to the old generation"
        )
        let requests = await client.requests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, staleCursor, rebaseCursor, secondRebaseCursor]
        )

        // The adopted cursor is the one the rebase chain ended on.
        let followUp = Task { await model.loadNextPage() }
        await waitUntil("post-rebase continuation request") {
            await client.requestCount == 6
        }
        await client.release(
            requestID: 5,
            page: ClipboardHistoryPage(
                entries: [entry(5)],
                nextCursor: nil,
                cursorDisposition: .continued
            )
        )
        await followUp.value
        let followUpRequests = await client.requests
        XCTAssertEqual(followUpRequests.last?.cursor, thirdRebaseCursor)
    }

    func testRepeatedRestartAbortsTheRebaseAndKeepsTheLoadedPrefix() async {
        let original = (0..<2).map(entry)
        let firstCursor = cursor("first")
        let firstRestartCursor = cursor("restart-1")
        let secondRestartCursor = cursor("restart-2")
        let recovered = entry(3)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: original,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [entry(100), original[0]],
                    nextCursor: firstRestartCursor,
                    cursorDisposition: .restarted
                ),
                // Restart #2: the rebase starts over from this head.
                ClipboardHistoryPage(
                    entries: [entry(101), entry(100)],
                    nextCursor: secondRestartCursor,
                    cursorDisposition: .restarted
                ),
                // Restart #3: the store is mutating faster than the prefix can
                // be rebuilt, so the rebase gives up instead of live-locking.
                ClipboardHistoryPage(
                    entries: [entry(102), entry(101)],
                    nextCursor: cursor("restart-3"),
                    cursorDisposition: .restarted
                ),
                ClipboardHistoryPage(
                    entries: [recovered],
                    nextCursor: nil,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        model.select(original[1].id)

        await model.loadNextPage()

        XCTAssertEqual(model.entries.map(\.id), original.map(\.id))
        XCTAssertEqual(model.selectedID, original[1].id)
        XCTAssertEqual(model.pagingState, .failed)
        XCTAssertNil(model.actionFailure)

        // The old cursor is retained, so a later attempt simply retries.
        await model.loadNextPage()

        XCTAssertEqual(
            model.entries.map(\.id),
            original.map(\.id) + [recovered.id]
        )
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.map(\.cursor),
            [
                nil,
                firstCursor,
                firstRestartCursor,
                secondRestartCursor,
                firstCursor,
            ]
        )
    }

    func testSelectionMadeDuringARebaseSurvivesTheAtomicReplace() async {
        let original = (0..<2).map(entry)
        let captured = entry(100)
        let deeper = entry(2)
        let firstCursor = cursor("first")
        let rebaseCursor = cursor("rebase")
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: original,
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value
        XCTAssertEqual(model.selectedID, original[0].id)

        let rebase = Task { await model.loadNextPage() }
        await waitUntil("stale continuation request") {
            await client.requestCount == 2
        }
        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [captured, original[0]],
                nextCursor: rebaseCursor,
                cursorDisposition: .restarted
            )
        )
        await waitUntil("rebase continuation request") {
            await client.requestCount == 3
        }

        // The old entries are still on screen, so the user can still act on
        // them. The model is reentrant across the rebase's awaits, so this
        // choice must not be undone by a selection snapshotted before them.
        model.select(original[1].id)

        await client.release(
            requestID: 2,
            page: ClipboardHistoryPage(
                entries: [original[1], deeper],
                nextCursor: nil,
                cursorDisposition: .continued
            )
        )
        await rebase.value

        XCTAssertEqual(
            model.entries.map(\.id),
            [captured.id, original[0].id, original[1].id, deeper.id]
        )
        XCTAssertEqual(
            model.selectedID,
            original[1].id,
            "a selection made while the old prefix was visible wins over the "
                + "one the rebase started with"
        )
        XCTAssertEqual(model.pagingState, .complete)
    }

    func testBudgetExhaustionKeepsTheOldPrefixInsteadOfShrinkingIt() async {
        let original = (0..<9).map(entry)
        let firstCursor = cursor("first")
        let restartCursor = cursor("restart")
        let continuationCursors = (2...5).map { cursor("rebase-\($0)") }
        let recovered = entry(200)
        // The restarted head is four entries wide against a nine-entry prefix,
        // so the walk may spend ceil(9 / 4) + 1 = 4 continuation fetches. Every
        // continuation returns a single entry, so the budget runs out with the
        // accumulator at 8 — one short of the old depth — and a cursor still in
        // hand. Publishing that would take a row away from the user.
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: original,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: (100..<104).map(entry),
                    nextCursor: restartCursor,
                    cursorDisposition: .restarted
                ),
            ] + continuationCursors.enumerated().map { index, nextCursor in
                ClipboardHistoryPage(
                    entries: [entry(104 + index)],
                    nextCursor: nextCursor,
                    cursorDisposition: .continued
                )
            } + [
                ClipboardHistoryPage(
                    entries: [recovered],
                    nextCursor: nil,
                    cursorDisposition: .continued
                )
            ],
            counts: [9]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        model.select(original[4].id)

        await model.loadNextPage()

        XCTAssertEqual(
            model.entries.map(\.id),
            original.map(\.id),
            "an exhausted rebase must never replace the visible prefix with a "
                + "shallower one"
        )
        XCTAssertEqual(model.selectedID, original[4].id)
        XCTAssertEqual(model.pagingState, .failed)
        XCTAssertEqual(model.totalCount, 9)
        XCTAssertNil(model.actionFailure)

        // The old cursor is retained, so the failure is retryable.
        await model.loadNextPage()

        XCTAssertEqual(
            model.entries.map(\.id),
            original.map(\.id) + [recovered.id]
        )
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.map(\.cursor),
            [
                nil,
                firstCursor,
                restartCursor,
                continuationCursors[0],
                continuationCursors[1],
                continuationCursors[2],
                firstCursor,
            ]
        )
    }

    func testUnavailableReloadClearsTheStaleTotal() async {
        let entries = (0..<3).map(entry)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: entries,
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            ],
            counts: [12]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        XCTAssertEqual(model.totalCount, 12)

        await client.setStatus(
            ClipboardHistoryStatus(
                availability: .unavailable,
                reason: .missingKey,
                isMonitoring: false
            )
        )
        await model.reload()

        XCTAssertEqual(model.contentState, .unavailable(.missingKey))
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(
            model.totalCount,
            "a total that describes a store the model can no longer read is a "
                + "lie, not a cached value"
        )
        XCTAssertEqual(model.pagingState, .complete)
    }

    func testQueryChangeDiscardsARebaseThatIsStillInFlight() async {
        let original = (0..<2).map(entry)
        let replacement = entry(200)
        let firstCursor = cursor("first")
        let rebaseCursor = cursor("rebase")
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: original,
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value

        let rebase = Task { await model.loadNextPage() }
        await waitUntil("stale continuation request") {
            await client.requestCount == 2
        }
        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [entry(100), original[0]],
                nextCursor: rebaseCursor,
                cursorDisposition: .restarted
            )
        )
        await waitUntil("rebase continuation request") {
            await client.requestCount == 3
        }

        let replacementLoad = Task {
            await model.setQuery(ClipboardHistoryQuery(text: "needle"))
        }
        await waitUntil("replacement query page request") {
            await client.requestCount == 4
        }
        await waitUntil("in-flight rebase cancellation") {
            await client.cancelledRequestIDs.contains(2)
        }
        await client.release(
            requestID: 3,
            page: ClipboardHistoryPage(
                entries: [replacement],
                nextCursor: nil,
                cursorDisposition: .initial
            )
        )
        await replacementLoad.value
        await client.release(
            requestID: 2,
            page: ClipboardHistoryPage(
                entries: (0..<4).map(entry),
                nextCursor: cursor("orphan"),
                cursorDisposition: .continued
            )
        )
        await rebase.value

        XCTAssertEqual(model.entries.map(\.id), [replacement.id])
        XCTAssertEqual(model.query.text, "needle")
        XCTAssertEqual(model.pagingState, .complete)
        XCTAssertNil(model.actionFailure)
    }

    /// ⌘→ from the middle of the loaded prefix is a selection move, not a
    /// fetch: the tail is already on screen, and reaching it is what tells the
    /// user where the loaded history currently ends.
    func testEndNavigationReachesTheLoadedTailBeforeFetchingAnything() async {
        let firstPage = (0..<3).map(entry)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: cursor("first"),
                    cursorDisposition: .initial
                )
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()
        model.select(firstPage[0].id)

        await model.moveTowardHistoryEnd()

        XCTAssertEqual(model.selectedID, firstPage[2].id)
        XCTAssertEqual(model.pagingState, .moreAvailable)
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.count,
            1,
            "reaching an already loaded tail may not cost a page"
        )
    }

    /// With the whole result set loaded there is nothing behind the tail, so a
    /// press that is already there is inert — the stub is out of pages, so any
    /// fetch would show up as a paging failure.
    func testEndNavigationOnACompletePrefixNeverFetches() async {
        let onlyPage = (0..<3).map(entry)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: onlyPage,
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        await model.moveTowardHistoryEnd()
        await model.moveTowardHistoryEnd()

        XCTAssertEqual(model.selectedID, onlyPage[2].id)
        XCTAssertEqual(model.entries.map(\.id), onlyPage.map(\.id))
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.pageRequests
        XCTAssertEqual(requests.count, 1)
    }

    /// The press that lands on a tail with more history behind it extends the
    /// prefix by exactly one page and follows it, so the highlight never claims
    /// a boundary that is only how far paging has got.
    func testEndNavigationFromTheTailLoadsOnePageAndFollowsIt() async {
        let firstPage = (0..<2).map(entry)
        let secondPage = [entry(2), entry(3)]
        let firstCursor = cursor("first")
        let secondCursor = cursor("second")
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: secondPage,
                    nextCursor: secondCursor,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        await model.moveTowardHistoryEnd()
        XCTAssertEqual(model.selectedID, firstPage[1].id)

        await model.moveTowardHistoryEnd()

        XCTAssertEqual(
            model.entries.map(\.id),
            (firstPage + secondPage).map(\.id)
        )
        XCTAssertEqual(model.selectedID, secondPage[1].id)
        XCTAssertEqual(model.pagingState, .moreAvailable)
        let requests = await client.pageRequests
        XCTAssertEqual(requests.map(\.cursor), [nil, firstCursor])
    }

    /// A `.restarted` page rebases the prefix onto the current index
    /// generation, and that replacement may legally be no deeper than what it
    /// replaces — a capture landed and retention evicted the tail the wall was
    /// holding. The replacement's tail is then a different, *newer* entry, so
    /// following it by identity would drag the selection back toward the head
    /// while still presenting it as the end of the history. Only real growth
    /// may be followed.
    func testEndNavigationDoesNotFollowARebaseThatDoesNotDeepenThePrefix()
        async
    {
        let firstPage = (0..<3).map(entry)
        // The capture that bumped the index generation and invalidated the
        // cursor the wall was holding.
        let captured = entry(100)
        let firstCursor = cursor("first")
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                // The new generation is shorter than the prefix it replaces,
                // and it ends here.
                ClipboardHistoryPage(
                    entries: [captured, firstPage[0]],
                    nextCursor: nil,
                    cursorDisposition: .restarted
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        await model.moveTowardHistoryEnd()
        XCTAssertEqual(model.selectedID, firstPage[2].id)

        await model.moveTowardHistoryEnd()

        XCTAssertEqual(
            model.entries.map(\.id),
            [captured.id, firstPage[0].id]
        )
        XCTAssertEqual(model.pagingState, .complete)
        XCTAssertEqual(
            model.selectedID,
            captured.id,
            """
            the selection the rebase reconciled to must stand: the prefix was \
            replaced, not extended, so the press has nothing to follow
            """
        )
        let requests = await client.pageRequests
        XCTAssertEqual(requests.map(\.cursor), [nil, firstCursor])
    }

    /// A page that fails to load leaves the selection where the user can see
    /// it, and the retained cursor turns the next press into the retry.
    func testFailedEndNavigationKeepsTheSelectionAndRetriesOnTheNextPress()
        async
    {
        let firstPage = (0..<2).map(entry)
        let recovered = entry(2)
        let firstCursor = cursor("first")
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: firstPage,
                    nextCursor: firstCursor,
                    cursorDisposition: .initial
                ),
                ClipboardHistoryPage(
                    entries: [],
                    nextCursor: nil,
                    cursorDisposition: .continued,
                    state: .failed(.stateUnavailable)
                ),
                ClipboardHistoryPage(
                    entries: [recovered],
                    nextCursor: nil,
                    cursorDisposition: .continued
                ),
            ]
        )
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )
        await model.load()

        await model.moveTowardHistoryEnd()
        await model.moveTowardHistoryEnd()

        XCTAssertEqual(model.pagingState, .failed)
        XCTAssertEqual(model.entries.map(\.id), firstPage.map(\.id))
        XCTAssertEqual(model.selectedID, firstPage[1].id)
        XCTAssertNil(
            model.actionFailure,
            "a paging failure is a boundary condition, not a destructive one"
        )

        await model.moveTowardHistoryEnd()

        XCTAssertEqual(
            model.entries.map(\.id),
            firstPage.map(\.id) + [recovered.id]
        )
        XCTAssertEqual(model.selectedID, recovered.id)
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.pageRequests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, firstCursor],
            "the retry must resume from the cursor the failure retained"
        )
    }

    /// A held-down ⌘→ must not stack page requests: while a fetch is in flight
    /// the selection is already as deep as the loaded prefix goes, so a repeat
    /// is inert rather than a second request for the same cursor.
    func testConcurrentEndNavigationIssuesASingleFetch() async {
        let firstPage = (0..<2).map(entry)
        let next = entry(2)
        let firstCursor = cursor("first")
        let client = ControlledPresentationClient()
        let model = ClipboardHistoryPresentationModel(
            operations: client.operations
        )

        let initialLoad = Task { await model.load() }
        await waitUntil("initial page request") {
            await client.requestCount == 1
        }
        await client.release(
            requestID: 0,
            page: ClipboardHistoryPage(
                entries: firstPage,
                nextCursor: firstCursor,
                cursorDisposition: .initial
            )
        )
        await initialLoad.value

        // The first press only walks to the loaded tail.
        await model.moveTowardHistoryEnd()
        XCTAssertEqual(model.selectedID, firstPage[1].id)
        let requestCountAfterWalk = await client.requestCount
        XCTAssertEqual(requestCountAfterWalk, 1)

        let inFlight = Task { await model.moveTowardHistoryEnd() }
        await waitUntil("load-more request") {
            await client.requestCount == 2
        }
        XCTAssertEqual(model.pagingState, .loading)

        await model.moveTowardHistoryEnd()

        let requestCountDuringFlight = await client.requestCount
        XCTAssertEqual(requestCountDuringFlight, 2)
        XCTAssertEqual(model.selectedID, firstPage[1].id)

        await client.release(
            requestID: 1,
            page: ClipboardHistoryPage(
                entries: [next],
                nextCursor: nil,
                cursorDisposition: .continued
            )
        )
        await inFlight.value

        XCTAssertEqual(
            model.entries.map(\.id),
            firstPage.map(\.id) + [next.id]
        )
        XCTAssertEqual(model.selectedID, next.id)
        XCTAssertEqual(model.pagingState, .complete)
        let requests = await client.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, firstCursor])
    }

    private func cursor(_ token: String) -> ClipboardHistoryCursor {
        ClipboardHistoryCursor(token: Data(token.utf8))
    }

    private func entry(_ index: Int) -> ClipboardHistoryEntry {
        ClipboardHistoryEntry(
            id: ClipboardHistoryEntryID(
                UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
            ),
            capturedAt: Date(timeIntervalSince1970: TimeInterval(10_000 - index)),
            previewText: "Entry \(index)",
            facets: [.text],
            isFavorite: false,
            source: .unknown
        )
    }

    private func materializationModel(
        returning materialization: ClipboardHistoryMaterialization
    ) -> ClipboardHistoryPresentationModel {
        ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in
                    ClipboardHistoryPage(
                        entries: [],
                        nextCursor: nil,
                        cursorDisposition: .initial
                    )
                },
                apply: { _ in .notFound },
                materialize: { _ in materialization },
                tagDefinitions: { [] }
            )
        )
    }
}

private actor ControlledPresentationClient {
    struct Request: Sendable {
        let query: ClipboardHistoryQuery
        let cursor: ClipboardHistoryCursor?
    }

    private var nextRequestID = 0
    private var continuations:
        [Int: CheckedContinuation<ClipboardHistoryPage, Never>] = [:]
    /// Answered immediately (counts are never the thing under test here); `nil`
    /// makes the count fail.
    private var countValue: Int?
    private(set) var requests: [Request] = []
    private(set) var cancelledRequestIDs: Set<Int> = []

    var requestCount: Int {
        requests.count
    }

    nonisolated var operations: ClipboardHistoryPresentationOperations {
        ClipboardHistoryPresentationOperations(
            status: {
                ClipboardHistoryStatus(
                    availability: .ready,
                    isMonitoring: true,
                    searchIndex: .ready
                )
            },
            page: { query, cursor in
                try await self.page(query: query, cursor: cursor)
            },
            count: { _ in
                try await self.currentCount()
            },
            apply: { _ in .notFound },
            materialize: { _ in
                ClipboardHistoryMaterialization(items: [])
            },
            tagDefinitions: { [] }
        )
    }

    func setCount(_ value: Int?) {
        countValue = value
    }

    func release(
        requestID: Int,
        page: ClipboardHistoryPage
    ) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: page
        )
    }

    private func currentCount() throws -> Int {
        guard let countValue else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return countValue
    }

    private func page(
        query: ClipboardHistoryQuery,
        cursor: ClipboardHistoryCursor?
    ) async throws -> ClipboardHistoryPage {
        let requestID = nextRequestID
        nextRequestID += 1
        requests.append(Request(query: query, cursor: cursor))
        return try await withTaskCancellationHandler {
            let page = await withCheckedContinuation { continuation in
                continuations[requestID] = continuation
            }
            try Task.checkCancellation()
            return page
        } onCancel: {
            Task {
                await self.recordCancellation(requestID)
            }
        }
    }

    private func recordCancellation(_ requestID: Int) {
        cancelledRequestIDs.insert(requestID)
    }
}

private actor TagPresentationClient {
    private var entry: ClipboardHistoryEntry
    private var tags: [ClipboardHistoryTagDefinition]
    private let failure: ClipboardHistoryModuleError?

    init(
        entry: ClipboardHistoryEntry,
        tags: [ClipboardHistoryTagDefinition],
        failure: ClipboardHistoryModuleError? = nil
    ) {
        self.entry = entry
        self.tags = tags
        self.failure = failure
    }

    nonisolated var operations: ClipboardHistoryPresentationOperations {
        ClipboardHistoryPresentationOperations(
            status: {
                ClipboardHistoryStatus(
                    availability: .ready,
                    isMonitoring: true,
                    searchIndex: .ready
                )
            },
            page: { _, _ in
                await ClipboardHistoryPage(
                    entries: [self.entry],
                    nextCursor: nil,
                    cursorDisposition: .initial
                )
            },
            apply: { _ in .notFound },
            materialize: { _ in
                ClipboardHistoryMaterialization(items: [])
            },
            tagDefinitions: { await self.tags },
            createTagDefinition: { name, entryID in
                try await self.create(name: name, entryID: entryID)
            },
            renameTagDefinition: { id, name in
                try await self.rename(id: id, name: name)
            },
            deleteTagDefinition: { id in
                try await self.delete(id: id)
            }
        )
    }

    private func create(
        name: String,
        entryID: ClipboardHistoryEntryID
    ) throws -> ClipboardHistoryTagAssignment {
        if let failure { throw failure }
        let definition = ClipboardHistoryTagDefinition(
            id: "project",
            displayName: name
        )
        tags.append(definition)
        entry = ClipboardHistoryEntry(
            id: entryID,
            capturedAt: entry.capturedAt,
            previewText: entry.previewText,
            facets: entry.facets,
            isFavorite: entry.isFavorite,
            tagIDs: [definition.id],
            source: entry.source
        )
        return ClipboardHistoryTagAssignment(
            definition: definition,
            entry: entry
        )
    }

    private func rename(
        id: String,
        name: String
    ) throws -> ClipboardHistoryTagDefinition {
        if let failure { throw failure }
        let definition = ClipboardHistoryTagDefinition(
            id: id,
            displayName: name
        )
        if let index = tags.firstIndex(where: { $0.id == id }) {
            tags[index] = definition
        }
        return definition
    }

    private func delete(
        id: String
    ) throws -> ClipboardHistoryTagDefinitionUpdate {
        if let failure { throw failure }
        tags.removeAll { $0.id == id }
        entry = ClipboardHistoryEntry(
            id: entry.id,
            capturedAt: entry.capturedAt,
            previewText: entry.previewText,
            facets: entry.facets,
            isFavorite: entry.isFavorite,
            tagIDs: entry.tagIDs.subtracting([id]),
            source: entry.source
        )
        return ClipboardHistoryTagDefinitionUpdate(
            removedMembershipCount: 1,
            unprotectedEntryCount: 1
        )
    }
}

private actor MaterializeCounter {
    private var counts: [ClipboardHistoryEntryID: Int] = [:]

    func record(_ entryID: ClipboardHistoryEntryID) {
        counts[entryID, default: 0] += 1
    }

    func count(for entryID: ClipboardHistoryEntryID) -> Int {
        counts[entryID] ?? 0
    }
}

private actor PresentationClientStub {
    struct PageRequest: Sendable {
        let query: ClipboardHistoryQuery
        let cursor: ClipboardHistoryCursor?
    }

    private var configuredStatus: ClipboardHistoryStatus
    private var pages: [ClipboardHistoryPage]
    /// Consumed like `pages`, except the last value repeats. An empty list
    /// makes every count fail, which is the "count unavailable" case.
    private var counts: [Int]
    private let applyError: (any Error)?
    private let sourceSummaries: [ClipboardHistorySourceSummary]
    private(set) var pageRequests: [PageRequest] = []
    private(set) var countRequests: [ClipboardHistoryQuery] = []

    init(
        status: ClipboardHistoryStatus = ClipboardHistoryStatus(
            availability: .ready,
            isMonitoring: true,
            searchIndex: .ready
        ),
        pages: [ClipboardHistoryPage],
        counts: [Int] = [],
        applyError: (any Error)? = nil,
        sourceSummaries: [ClipboardHistorySourceSummary] = []
    ) {
        configuredStatus = status
        self.pages = pages
        self.counts = counts
        self.applyError = applyError
        self.sourceSummaries = sourceSummaries
    }

    nonisolated var operations: ClipboardHistoryPresentationOperations {
        ClipboardHistoryPresentationOperations(
            status: { await self.configuredStatusValue() },
            page: { query, cursor in
                try await self.nextPage(query: query, cursor: cursor)
            },
            count: { query in
                try await self.nextCount(query: query)
            },
            apply: { mutation in
                try await self.applyMutation(mutation)
            },
            materialize: { _ in
                ClipboardHistoryMaterialization(items: [])
            },
            tagDefinitions: { [] },
            sourceSummaries: { await self.configuredSourceSummaries() }
        )
    }

    func setStatus(_ status: ClipboardHistoryStatus) {
        configuredStatus = status
    }

    private func configuredStatusValue() -> ClipboardHistoryStatus {
        configuredStatus
    }

    private func configuredSourceSummaries()
        -> [ClipboardHistorySourceSummary]
    {
        sourceSummaries
    }

    private func nextPage(
        query: ClipboardHistoryQuery,
        cursor: ClipboardHistoryCursor?
    ) throws -> ClipboardHistoryPage {
        pageRequests.append(PageRequest(query: query, cursor: cursor))
        guard !pages.isEmpty else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return pages.removeFirst()
    }

    private func nextCount(query: ClipboardHistoryQuery) throws -> Int {
        countRequests.append(query)
        guard let first = counts.first else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        if counts.count > 1 {
            counts.removeFirst()
        }
        return first
    }

    private func applyMutation(
        _ mutation: ClipboardHistoryMutation
    ) throws -> ClipboardHistoryMutationOutcome {
        _ = mutation
        if let applyError {
            throw applyError
        }
        return .deleted
    }
}
