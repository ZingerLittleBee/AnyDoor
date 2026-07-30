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

private actor PresentationClientStub {
    struct PageRequest: Sendable {
        let query: ClipboardHistoryQuery
        let cursor: ClipboardHistoryCursor?
    }

    private let configuredStatus: ClipboardHistoryStatus
    private var pages: [ClipboardHistoryPage]
    private let applyError: (any Error)?
    private(set) var pageRequests: [PageRequest] = []

    init(
        status: ClipboardHistoryStatus = ClipboardHistoryStatus(
            availability: .ready,
            isMonitoring: true,
            searchIndex: .ready
        ),
        pages: [ClipboardHistoryPage],
        applyError: (any Error)? = nil
    ) {
        configuredStatus = status
        self.pages = pages
        self.applyError = applyError
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
            tagDefinitions: { [] }
        )
    }

    private func configuredStatusValue() -> ClipboardHistoryStatus {
        configuredStatus
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
