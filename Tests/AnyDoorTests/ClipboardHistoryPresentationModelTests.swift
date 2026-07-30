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
                    nextCursor: cursor
                )
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)

        await model.load()

        XCTAssertEqual(model.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.selectedID, first.id)
        XCTAssertEqual(model.contentState, .content)
        XCTAssertTrue(model.canLoadMore)
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
                ClipboardHistoryPage(entries: firstPage, nextCursor: cursor),
                ClipboardHistoryPage(entries: [next], nextCursor: nil),
            ]
        )
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.load()

        await model.prefetchIfNeeded(visibleID: firstPage[94].id)
        await model.prefetchIfNeeded(visibleID: firstPage[99].id)

        XCTAssertEqual(model.entries.count, 101)
        XCTAssertEqual(model.entries.last?.id, next.id)
        XCTAssertFalse(model.canLoadMore)
        let requests = await client.pageRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[1].cursor, cursor)
    }

    func testChangingQueryAndFiltersInvalidatesCursor() async {
        let cursor = ClipboardHistoryCursor(token: Data("next".utf8))
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(entries: [entry(0)], nextCursor: cursor),
                ClipboardHistoryPage(entries: [entry(1)], nextCursor: cursor),
                ClipboardHistoryPage(entries: [entry(2)], nextCursor: nil),
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
                sourceID: "com.example.Source",
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
        XCTAssertEqual(requests[2].query.sourceID, "com.example.Source")
        XCTAssertEqual(requests[2].query.tagID, "work")
        XCTAssertTrue(requests[2].query.favoritesOnly)
    }

    func testReloadPreservesSelectionWhenEntryStillExists() async {
        let selected = entry(1)
        let client = PresentationClientStub(
            pages: [
                ClipboardHistoryPage(
                    entries: [entry(0), selected],
                    nextCursor: nil
                ),
                ClipboardHistoryPage(
                    entries: [entry(2), selected],
                    nextCursor: nil
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
                ClipboardHistoryPage(entries: [], nextCursor: nil)
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
                    nextCursor: nil
                ),
                ClipboardHistoryPage(entries: [], nextCursor: nil),
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
            ClipboardHistoryQuery(sourceID: "com.example.Empty")
        )

        XCTAssertEqual(
            model.sources,
            [
                ClipboardHistoryPresentationSource(
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
                nextCursor: nil
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
                state: .failed(.rebuildFailed)
            )
        )
        await initialLoad.value

        XCTAssertEqual(model.entries, [replacement])
        XCTAssertEqual(model.query.text, "needle")
        XCTAssertFalse(model.canLoadMore)
        XCTAssertNil(model.actionFailure)
        let requests = await client.requests
        XCTAssertEqual(requests.map(\.cursor), [nil, nil])
    }

    func testChangingEachFilterDiscardsSuspendedInitialPage() async {
        let filters = [
            ClipboardHistoryQuery(facet: .image),
            ClipboardHistoryQuery(sourceID: "com.example.Source"),
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
                    nextCursor: nil
                )
            )
            await replacementLoad.value
            await client.release(
                requestID: 0,
                page: ClipboardHistoryPage(
                    entries: [entry(60 + index)],
                    nextCursor: ClipboardHistoryCursor(
                        token: Data("stale-\(index)".utf8)
                    )
                )
            )
            await initialLoad.value

            XCTAssertEqual(model.query, filter)
            XCTAssertEqual(model.entries, [replacement])
            XCTAssertFalse(model.canLoadMore)
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
                nextCursor: firstCursor
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
                nextCursor: replacementCursor
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
                state: .failed(.stateUnavailable)
            )
        )
        await stalePrefetch.value

        XCTAssertEqual(model.entries, [replacement])
        XCTAssertTrue(model.canLoadMore)
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
                nextCursor: nil
            )
        )
        await replacementPrefetch.value

        XCTAssertEqual(model.entries, [replacement, final])
        XCTAssertFalse(model.canLoadMore)
        let requests = await client.requests
        XCTAssertEqual(
            requests.map(\.cursor),
            [nil, firstCursor, nil, replacementCursor]
        )
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
                    ClipboardHistoryPage(entries: [], nextCursor: nil)
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
            apply: { _ in .notFound },
            materialize: { _ in
                ClipboardHistoryMaterialization(items: [])
            },
            tagDefinitions: { [] }
        )
    }

    func release(
        requestID: Int,
        page: ClipboardHistoryPage
    ) {
        continuations.removeValue(forKey: requestID)?.resume(
            returning: page
        )
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
                    nextCursor: nil
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

private actor PresentationClientStub {
    struct PageRequest: Sendable {
        let query: ClipboardHistoryQuery
        let cursor: ClipboardHistoryCursor?
    }

    private let configuredStatus: ClipboardHistoryStatus
    private var pages: [ClipboardHistoryPage]
    private let applyError: (any Error)?
    private let sourceSummaries: [ClipboardHistorySourceSummary]
    private(set) var pageRequests: [PageRequest] = []

    init(
        status: ClipboardHistoryStatus = ClipboardHistoryStatus(
            availability: .ready,
            isMonitoring: true,
            searchIndex: .ready
        ),
        pages: [ClipboardHistoryPage],
        applyError: (any Error)? = nil,
        sourceSummaries: [ClipboardHistorySourceSummary] = []
    ) {
        configuredStatus = status
        self.pages = pages
        self.applyError = applyError
        self.sourceSummaries = sourceSummaries
    }

    nonisolated var operations: ClipboardHistoryPresentationOperations {
        ClipboardHistoryPresentationOperations(
            status: { await self.configuredStatusValue() },
            page: { query, cursor in
                try await self.nextPage(query: query, cursor: cursor)
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
