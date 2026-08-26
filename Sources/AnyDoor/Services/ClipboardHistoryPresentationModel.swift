import ClipboardHistory
import Foundation
import Observation

struct ClipboardHistoryPresentationOperations: Sendable {
    let status: @Sendable () async -> ClipboardHistoryStatus
    let page:
        @Sendable (
            ClipboardHistoryQuery,
            ClipboardHistoryCursor?
        ) async throws -> ClipboardHistoryPage
    /// Best-effort total for the same query the pages are drawn from. It shares
    /// the typed filters and the FTS predicate with `page`, so the two agree,
    /// but a failure here must only make the total unavailable — it may never
    /// fail or replace a page that already loaded.
    let count:
        @Sendable (
            ClipboardHistoryQuery
        ) async throws -> Int
    let apply:
        @Sendable (
            ClipboardHistoryMutation
        ) async throws -> ClipboardHistoryMutationOutcome
    let materialize:
        @Sendable (
            ClipboardHistoryMaterializationRequest
        ) async throws -> ClipboardHistoryMaterialization
    let tagDefinitions:
        @Sendable () async throws -> [ClipboardHistoryTagDefinition]
    let sourceSummaries:
        @Sendable () async throws -> [ClipboardHistorySourceSummary]
    let createTagDefinition:
        @Sendable (
            String,
            ClipboardHistoryEntryID
        ) async throws -> ClipboardHistoryTagAssignment
    let renameTagDefinition:
        @Sendable (
            String,
            String
        ) async throws -> ClipboardHistoryTagDefinition
    let deleteTagDefinition:
        @Sendable (
            String
        ) async throws -> ClipboardHistoryTagDefinitionUpdate
    let legacyFileRestorePlan:
        @Sendable (
            ClipboardHistoryEntryID
        ) async throws -> ClipboardHistoryLegacyFileRestorePlan
    let restoreLegacyOwnedFiles:
        @Sendable (
            ClipboardHistoryLegacyFileRestoreRequest
        ) async throws -> ClipboardHistoryLegacyFileRestoreOutcome

    init(module: ClipboardHistoryModule) {
        status = { await module.status() }
        page = { query, cursor in
            try await module.page(query, after: cursor)
        }
        count = { query in
            try await module.count(query)
        }
        apply = { mutation in
            try await module.apply(mutation)
        }
        materialize = { request in
            try await module.materialize(request)
        }
        tagDefinitions = {
            try await module.tagDefinitions()
        }
        sourceSummaries = {
            try await module.sourceSummaries()
        }
        createTagDefinition = { name, entryID in
            let assignment = try await module.createTagDefinition(
                named: name,
                assigningTo: entryID
            )
            try await ClipboardHistoryPortableSettings.persist(
                module.tagDefinitions()
            )
            return assignment
        }
        renameTagDefinition = { id, name in
            let definition = try await module.renameTagDefinition(
                id: id,
                to: name
            )
            try await ClipboardHistoryPortableSettings.persist(
                module.tagDefinitions()
            )
            return definition
        }
        deleteTagDefinition = { id in
            let update = try await module.deleteTagDefinition(id: id)
            try await ClipboardHistoryPortableSettings.persist(
                module.tagDefinitions()
            )
            return update
        }
        legacyFileRestorePlan = { entryID in
            try await module.legacyFileRestorePlan(for: entryID)
        }
        restoreLegacyOwnedFiles = { request in
            try await module.restoreLegacyOwnedFiles(request)
        }
    }

    init(
        status: @escaping @Sendable () async -> ClipboardHistoryStatus,
        page:
            @escaping @Sendable (
                ClipboardHistoryQuery,
                ClipboardHistoryCursor?
            ) async throws -> ClipboardHistoryPage,
        count:
            @escaping @Sendable (
                ClipboardHistoryQuery
            ) async throws -> Int = { _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            },
        apply:
            @escaping @Sendable (
                ClipboardHistoryMutation
            ) async throws -> ClipboardHistoryMutationOutcome,
        materialize:
            @escaping @Sendable (
                ClipboardHistoryMaterializationRequest
            ) async throws -> ClipboardHistoryMaterialization,
        tagDefinitions:
            @escaping @Sendable () async throws
                -> [ClipboardHistoryTagDefinition],
        sourceSummaries:
            @escaping @Sendable () async throws
                -> [ClipboardHistorySourceSummary] = { [] },
        createTagDefinition:
            @escaping @Sendable (
                String,
                ClipboardHistoryEntryID
            ) async throws -> ClipboardHistoryTagAssignment = { _, _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            },
        renameTagDefinition:
            @escaping @Sendable (
                String,
                String
            ) async throws -> ClipboardHistoryTagDefinition = { _, _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            },
        deleteTagDefinition:
            @escaping @Sendable (
                String
            ) async throws -> ClipboardHistoryTagDefinitionUpdate = { _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            },
        legacyFileRestorePlan:
            @escaping @Sendable (
                ClipboardHistoryEntryID
            ) async throws -> ClipboardHistoryLegacyFileRestorePlan = { _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            },
        restoreLegacyOwnedFiles:
            @escaping @Sendable (
                ClipboardHistoryLegacyFileRestoreRequest
            ) async throws -> ClipboardHistoryLegacyFileRestoreOutcome = { _ in
                throw ClipboardHistoryModuleError.operationUnavailable
            }
    ) {
        self.status = status
        self.page = page
        self.count = count
        self.apply = apply
        self.materialize = materialize
        self.tagDefinitions = tagDefinitions
        self.sourceSummaries = sourceSummaries
        self.createTagDefinition = createTagDefinition
        self.renameTagDefinition = renameTagDefinition
        self.deleteTagDefinition = deleteTagDefinition
        self.legacyFileRestorePlan = legacyFileRestorePlan
        self.restoreLegacyOwnedFiles = restoreLegacyOwnedFiles
    }
}

/// The single UI-facing signal about the tail of the loaded prefix.
///
/// It deliberately hides the opaque cursor, the single-flight latch and the
/// rebase machinery: a paging surface only needs to know whether there is more
/// history behind the last loaded entry, whether a fetch is in flight, and
/// whether the last attempt failed and can be retried.
enum ClipboardHistoryPagingState: Equatable {
    /// The loaded prefix reaches the end of the result set.
    case complete
    /// More history exists behind the last loaded entry.
    case moreAvailable
    /// A page (or a rebase chain) is being fetched. Loaded entries stay visible.
    case loading
    /// The last attempt failed. Loaded entries and the cursor are retained, so
    /// a later `loadNextPage()` retries from the same position.
    case failed
}

enum ClipboardHistoryContentState: Equatable {
    case loading
    case content
    case empty
    case indexing
    case unavailable(ClipboardHistoryStatus.AvailabilityReason?)
}

struct ClipboardHistoryPresentationSource: Equatable, Identifiable {
    let id: ClipboardHistorySourceID
    let bundleID: String?
    let name: String
    let count: Int
}

enum ClipboardHistoryActionFailure: Equatable {
    case operationUnavailable
    case entryNotFound
    case storeUnavailable
    case storageFailure
    case payloadAuthenticationFailed
    case payloadUnavailable
    case fileReferencesUnavailable(
        entryID: ClipboardHistoryEntryID,
        count: Int
    )
    case fileCollectionRequiresRestore(
        entryID: ClipboardHistoryEntryID,
        ownedCount: Int,
        unavailableCount: Int
    )
    case invalidTagIDs
    case invalidTagDefinition
    case invalidTextEdit
    case searchIndexFailed(ClipboardHistorySearchIndexFailure)
    case unknown

    init(_ error: any Error) {
        guard let moduleError = error as? ClipboardHistoryModuleError else {
            self = .unknown
            return
        }
        switch moduleError {
        case .operationUnavailable:
            self = .operationUnavailable
        case .entryNotFound:
            self = .entryNotFound
        case .storeUnavailable:
            self = .storeUnavailable
        case .storageFailure:
            self = .storageFailure
        case .payloadAuthenticationFailed:
            self = .payloadAuthenticationFailed
        case .payloadUnavailable:
            self = .payloadUnavailable
        case .fileReferencesUnavailable(let entryID, let count):
            self = .fileReferencesUnavailable(
                entryID: entryID,
                count: count
            )
        case .fileCollectionRequiresRestore(
            let entryID,
            let ownedCount,
            let unavailableCount
        ):
            self = .fileCollectionRequiresRestore(
                entryID: entryID,
                ownedCount: ownedCount,
                unavailableCount: unavailableCount
            )
        case .invalidTagIDs:
            self = .invalidTagIDs
        case .invalidTagName,
             .duplicateTagName,
             .tagDefinitionNotFound:
            self = .invalidTagDefinition
        case .invalidTextEdit:
            self = .invalidTextEdit
        case .resetFailed,
             .invalidConfirmation,
             .unsupportedLegacyTransferVersion,
             .legacyMigrationFailed,
             .invalidLegacyFileRestore,
             .legacyFileRestoreCollision,
             .legacyFileRestoreFailed,
             .legacyCleanupFailed:
            self = .unknown
        }
    }
}

@MainActor
@Observable
final class ClipboardHistoryPresentationModel {
    /// How close to the tail a visible entry has to be for the legacy
    /// `prefetchIfNeeded(visibleID:)` wrapper to ask for the next page. Only
    /// that wrapper uses it; a paging sentinel calls `loadNextPage()` directly.
    private static let prefetchDistance = 6
    /// A rebase may never turn into an unbounded chase of a store that keeps
    /// growing under it, so its continuation fetches are capped even if the
    /// derived budget would allow more.
    private static let rebasePageBudgetLimit = 64
    /// How many times a rebase may start over because a *second* `.restarted`
    /// page arrived while it was rebuilding. A further restart aborts instead,
    /// which is what stops a busy store from live-locking the paging tail.
    private static let rebaseRestartAllowance = 1
    /// A materialization holds the decrypted payload — for an image entry that
    /// is the whole bitmap. Paging is unbounded, so the cache has to be bounded
    /// explicitly or scrolling a long history with previews open grows the
    /// resident set without limit.
    private static let materializationCacheLimit = 16

    private let operations: ClipboardHistoryPresentationOperations
    private var nextCursor: ClipboardHistoryCursor?
    private var revision = 0
    private var isLoadingMore = false
    private var firstPageTask: Task<FirstPageResult, any Error>?
    private var pagingTask: Task<ClipboardHistoryPage, any Error>?
    private var materializationCache:
        [MaterializationKey: ClipboardHistoryMaterialization] = [:]
    /// Least-recently-used first. Kept in step with `materializationCache` by
    /// `cacheMaterialization` / `pruneMaterializations`.
    private var materializationOrder: [MaterializationKey] = []
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var query = ClipboardHistoryQuery()
    private(set) var selectedID: ClipboardHistoryEntryID?
    private(set) var contentState: ClipboardHistoryContentState = .loading
    private(set) var actionFailure: ClipboardHistoryActionFailure?
    private(set) var tags: [ClipboardHistoryTagDefinition] = []
    private(set) var sources: [ClipboardHistoryPresentationSource] = []
    private(set) var pagingState: ClipboardHistoryPagingState = .complete
    /// How many entries satisfy `query` in total, or `nil` while that is
    /// unknown. It is refreshed whenever a new generation of the prefix is
    /// published; a failed count only clears it and never disturbs the entries.
    private(set) var totalCount: Int?

    var selectedEntry: ClipboardHistoryEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    init(module: ClipboardHistoryModule) {
        operations = ClipboardHistoryPresentationOperations(module: module)
    }

    init(operations: ClipboardHistoryPresentationOperations) {
        self.operations = operations
    }

    func load() async {
        await loadFirstPage(preservingSelection: true)
    }

    func reload() async {
        await loadFirstPage(preservingSelection: true)
    }

    func setQuery(_ query: ClipboardHistoryQuery) async {
        guard query != self.query else { return }
        self.query = query
        await loadFirstPage(preservingSelection: true)
    }

    func retry() async {
        actionFailure = nil
        await loadFirstPage(preservingSelection: true)
    }

    func clearActionFailure() {
        actionFailure = nil
    }

    func legacyFileRestorePlan(
        for entryID: ClipboardHistoryEntryID
    ) async -> ClipboardHistoryLegacyFileRestorePlan? {
        actionFailure = nil
        do {
            return try await operations.legacyFileRestorePlan(entryID)
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
            return nil
        }
    }

    func restoreLegacyOwnedFiles(
        _ request: ClipboardHistoryLegacyFileRestoreRequest
    ) async -> Bool {
        actionFailure = nil
        do {
            _ = try await operations.restoreLegacyOwnedFiles(request)
            invalidateMaterializations(for: request.entryID)
            return true
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
            return false
        }
    }

    func createTagDefinition(
        named name: String,
        assigningTo entryID: ClipboardHistoryEntryID
    ) async -> Bool {
        actionFailure = nil
        do {
            let assignment = try await operations.createTagDefinition(
                name,
                entryID
            )
            upsertTagDefinition(assignment.definition)
            replaceEntry(assignment.entry)
            return true
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
            return false
        }
    }

    func renameTagDefinition(
        id: String,
        to name: String
    ) async -> Bool {
        actionFailure = nil
        do {
            let definition = try await operations.renameTagDefinition(
                id,
                name
            )
            upsertTagDefinition(definition)
            return true
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
            return false
        }
    }

    func deleteTagDefinition(id: String) async -> Bool {
        actionFailure = nil
        do {
            _ = try await operations.deleteTagDefinition(id)
            tags.removeAll { $0.id == id }
            entries = entries.map { entry in
                guard entry.tagIDs.contains(id) else { return entry }
                return ClipboardHistoryEntry(
                    id: entry.id,
                    capturedAt: entry.capturedAt,
                    previewText: entry.previewText,
                    facets: entry.facets,
                    isFavorite: entry.isFavorite,
                    tagIDs: entry.tagIDs.subtracting([id]),
                    source: entry.source
                )
            }
            return true
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
            return false
        }
    }

    func select(_ id: ClipboardHistoryEntryID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    func moveSelection(by delta: Int) {
        guard !entries.isEmpty else {
            selectedID = nil
            return
        }
        let current = selectedID.flatMap { selectedID in
            entries.firstIndex { $0.id == selectedID }
        } ?? 0
        let next = min(max(current + delta, 0), entries.count - 1)
        selectedID = entries[next].id
    }

    func moveSelectionToStart() {
        selectedID = entries.first?.id
    }

    func moveSelectionToEnd() {
        selectedID = entries.last?.id
    }

    /// Extends the loaded prefix by one page.
    ///
    /// This is the only fetch path for pages after the first one. It is
    /// single-flight: a second concurrent call returns immediately instead of
    /// issuing a second request for the same cursor, which is what makes it
    /// safe to drive from a key-repeat or from a scroll sentinel that appears
    /// and disappears while a fetch is already running.
    func loadNextPage() async {
        guard !isLoadingMore, let cursor = nextCursor else { return }

        let requestRevision = revision
        let requestQuery = query
        isLoadingMore = true
        pagingState = .loading
        defer {
            if requestRevision == revision {
                isLoadingMore = false
                pagingTask = nil
            }
        }
        do {
            let page = try await fetchPage(
                query: requestQuery,
                cursor: cursor
            )
            guard requestRevision == revision, requestQuery == query else {
                return
            }
            switch page.state {
            case .ready:
                if page.cursorDisposition == .restarted {
                    // The cursor was silently invalidated (a capture bumps the
                    // index generation), so this is the head of a *new*
                    // generation, not the continuation that was asked for.
                    // Appending it would splice the newest entries onto the
                    // oldest end of a newest-first prefix.
                    await rebase(
                        onto: page,
                        requestRevision: requestRevision,
                        requestQuery: requestQuery
                    )
                } else {
                    appendPage(page)
                }
            case .indexing:
                contentState = .indexing
                nextCursor = nil
                pagingState = .complete
            case .failed:
                // A search-index failure while paging is a boundary condition,
                // not a destructive one: the loaded entries stay on screen and
                // the cursor is retained so a retry can resume from here.
                pagingState = .failed
            }
        } catch {
            guard requestRevision == revision,
                !(error is CancellationError)
            else {
                return
            }
            pagingState = .failed
        }
    }

    /// Legacy per-row trigger kept for the history popover, which still drives
    /// paging from the last visible row rather than from a tail sentinel. It
    /// only owns the "near the tail" policy; the fetch itself is
    /// `loadNextPage()`, so there is exactly one paging implementation.
    func prefetchIfNeeded(visibleID: ClipboardHistoryEntryID) async {
        guard let index = entries.firstIndex(where: { $0.id == visibleID }),
            index >= max(0, entries.count - Self.prefetchDistance)
        else {
            return
        }
        await loadNextPage()
    }

    private func appendPage(_ page: ClipboardHistoryPage) {
        let existingIDs = Set(entries.map(\.id))
        entries.append(
            contentsOf: page.entries.filter { !existingIDs.contains($0.id) }
        )
        nextCursor = page.nextCursor
        pagingState = page.nextCursor == nil ? .complete : .moreAvailable
        reconcileSelection(preferredID: selectedID)
    }

    /// Rebuilds the loaded prefix against the current index generation after a
    /// cursor was invalidated, then publishes it in one step.
    ///
    /// `head` is the restarted page — the first page of the new generation. It
    /// is accumulated locally and the chain is followed until the accumulator
    /// covers the depth the user had already loaded plus one more page, the
    /// chain ends, or the fetch budget runs out. The entries currently on
    /// screen are untouched until that succeeds, so the wall never shows a
    /// half-rebased array.
    private func rebase(
        onto head: ClipboardHistoryPage,
        requestRevision: Int,
        requestQuery: ClipboardHistoryQuery
    ) async {
        let targetDepth = entries.count
        let preferredID = selectedID
        var restart = head
        var restartsRemaining = Self.rebaseRestartAllowance

        while true {
            var rebasedEntries: [ClipboardHistoryEntry] = []
            var seenIDs: Set<ClipboardHistoryEntryID> = []
            var page = restart
            var budget = Self.rebaseBudget(
                targetDepth: targetDepth,
                pageSize: restart.entries.count
            )
            var restartedAgain: ClipboardHistoryPage?

            chain: while true {
                for entry in page.entries {
                    guard seenIDs.insert(entry.id).inserted else { continue }
                    rebasedEntries.append(entry)
                }
                guard rebasedEntries.count <= targetDepth,
                    let cursor = page.nextCursor,
                    budget > 0
                else {
                    break chain
                }
                budget -= 1

                let fetched: ClipboardHistoryPage
                do {
                    fetched = try await fetchPage(
                        query: requestQuery,
                        cursor: cursor
                    )
                } catch {
                    guard requestRevision == revision,
                        !(error is CancellationError)
                    else {
                        return
                    }
                    pagingState = .failed
                    return
                }
                guard requestRevision == revision, requestQuery == query else {
                    return
                }
                guard case .ready = fetched.state else {
                    // The index went away mid-rebase. Keep what is on screen
                    // and let the user retry rather than publishing a prefix
                    // that is shallower than the one it would replace.
                    pagingState = .failed
                    return
                }
                if fetched.cursorDisposition == .restarted {
                    restartedAgain = fetched
                    break chain
                }
                page = fetched
            }

            if let restartedAgain {
                guard restartsRemaining > 0 else {
                    // The store is mutating faster than the prefix can be
                    // rebuilt. Keep the old entries and the old cursor and
                    // report a retryable failure instead of looping.
                    pagingState = .failed
                    return
                }
                restartsRemaining -= 1
                restart = restartedAgain
                continue
            }

            entries = rebasedEntries
            nextCursor = page.nextCursor
            pagingState = page.nextCursor == nil ? .complete : .moreAvailable
            contentState = entries.isEmpty ? .empty : .content
            reconcileSelection(preferredID: preferredID)
            let currentIDs = Set(entries.map(\.id))
            pruneMaterializations { currentIDs.contains($0.entryID) }
            // The old total belongs to the old generation.
            await refreshTotalCount(
                requestRevision: requestRevision,
                requestQuery: requestQuery
            )
            return
        }
    }

    /// How many continuation fetches a rebase may spend: roughly one walk of
    /// the depth that was already loaded, plus one page of slack so the result
    /// reaches "old depth + one page", and never more than the hard limit.
    private static func rebaseBudget(
        targetDepth: Int,
        pageSize: Int
    ) -> Int {
        guard pageSize > 0 else { return 0 }
        let pages = (targetDepth + pageSize - 1) / pageSize
        return min(pages + 1, rebasePageBudgetLimit)
    }

    private func fetchPage(
        query requestQuery: ClipboardHistoryQuery,
        cursor: ClipboardHistoryCursor?
    ) async throws -> ClipboardHistoryPage {
        let task = Task {
            try await operations.page(requestQuery, cursor)
        }
        pagingTask = task
        return try await task.value
    }

    private func refreshTotalCount(
        requestRevision: Int,
        requestQuery: ClipboardHistoryQuery
    ) async {
        let count = try? await operations.count(requestQuery)
        guard requestRevision == revision, requestQuery == query else {
            return
        }
        totalCount = count
    }

    /// Whether `mutation` can change *which* entries satisfy `query`, in which
    /// case the page has to be refetched instead of patched in place. Patching
    /// is the common path and is what keeps a deep scroll position (and the
    /// neighbouring selection) after deleting or favouriting one row — a blanket
    /// refetch would snap the wall back to the first page every time.
    static func requiresRefetch(
        for mutation: ClipboardHistoryMutation,
        query: ClipboardHistoryQuery
    ) -> Bool {
        switch mutation {
        case .delete:
            false
        case .setFavorite:
            query.favoritesOnly
        case .setTags:
            query.tagID != nil
        case .editText:
            !query.text.isEmpty
        }
    }

    func apply(_ mutation: ClipboardHistoryMutation) async {
        actionFailure = nil
        do {
            let outcome = try await operations.apply(mutation)
            switch outcome {
            case .updated(let entry):
                if let index = entries.firstIndex(where: { $0.id == entry.id }) {
                    entries[index] = entry
                }
                invalidateMaterializations(for: entry.id)
                if Self.requiresRefetch(for: mutation, query: query) {
                    await loadFirstPage(preservingSelection: true)
                }
            case .deleted:
                let entryID = mutation.entryID
                let deletedIndex = entries.firstIndex { $0.id == entryID }
                let deletedSourceID = deletedIndex.map {
                    entries[$0].source.sourceID
                }
                entries.removeAll { $0.id == entryID }
                if let deletedSourceID {
                    decrementSource(deletedSourceID)
                }
                if deletedIndex != nil, let current = totalCount {
                    // The row was part of this query's result set, and a delete
                    // never triggers a refetch, so the total has to be adjusted
                    // here or it stays stale for the rest of the session.
                    totalCount = max(0, current - 1)
                }
                invalidateMaterializations(for: entryID)
                if selectedID == entryID {
                    let replacementIndex = min(
                        deletedIndex ?? 0,
                        max(0, entries.count - 1)
                    )
                    selectedID = entries.indices.contains(replacementIndex)
                        ? entries[replacementIndex].id
                        : nil
                }
                if entries.isEmpty {
                    contentState = .empty
                }
            case .notFound:
                break
            }
        } catch {
            actionFailure = ClipboardHistoryActionFailure(error)
        }
    }

    func materialization(
        for entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose,
        usesCache: Bool = true,
        recordsFailure: Bool = true
    ) async -> ClipboardHistoryMaterialization? {
        let key = MaterializationKey(entryID: entryID, purpose: purpose)
        if usesCache, let cached = materializationCache[key] {
            touchMaterialization(key)
            return cached
        }
        let requestRevision = revision
        if recordsFailure {
            actionFailure = nil
        }
        do {
            let value = try await operations.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: entryID,
                    purpose: purpose
                )
            )
            if usesCache, requestRevision == revision {
                cacheMaterialization(value, for: key)
            }
            return value
        } catch {
            if recordsFailure, requestRevision == revision {
                actionFailure = ClipboardHistoryActionFailure(error)
            }
            return nil
        }
    }

    func cachedMaterialization(
        for entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose
    ) -> ClipboardHistoryMaterialization? {
        materializationCache[
            MaterializationKey(entryID: entryID, purpose: purpose)
        ]
    }

    func supportsPlainTextPaste(
        for entryID: ClipboardHistoryEntryID
    ) -> Bool {
        guard let materialization = cachedMaterialization(
            for: entryID,
            purpose: .hostAction
        ), let texts = materialization.exactTexts else {
            return false
        }
        return !materialization.items.isEmpty
            && texts.count == materialization.items.count
    }

    private func loadFirstPage(preservingSelection: Bool) async {
        firstPageTask?.cancel()
        pagingTask?.cancel()
        pagingTask = nil
        revision += 1
        let requestRevision = revision
        let preferredSelection = preservingSelection ? selectedID : nil
        let requestQuery = query
        nextCursor = nil
        isLoadingMore = false
        pagingState = .loading
        actionFailure = nil
        if entries.isEmpty {
            contentState = .loading
        }
        // `totalCount` is deliberately not cleared here. The entries currently
        // on screen stay visible until the new page lands, so blanking the
        // total first would make the pair disagree — and flicker — for the
        // duration of the load. Both are replaced together below.

        let task = Task { () throws -> FirstPageResult in
            let status = await operations.status()
            try Task.checkCancellation()
            guard status.availability == .ready else {
                return FirstPageResult(status: status)
            }
            async let page = operations.page(requestQuery, nil)
            async let definitions = operations.tagDefinitions()
            async let summaries = operations.sourceSummaries()
            // Counting runs beside the page but can only ever contribute a
            // value: a count failure leaves the total unknown and must not
            // fail the page it accompanies.
            async let count = Self.bestEffortCount(
                operations,
                requestQuery
            )
            let (loadedPage, loadedTags, loadedSources, loadedCount) =
                try await (page, definitions, summaries, count)
            try Task.checkCancellation()
            return FirstPageResult(
                status: status,
                page: loadedPage,
                tags: loadedTags,
                sources: loadedSources,
                totalCount: loadedCount
            )
        }
        firstPageTask = task
        defer {
            if requestRevision == revision {
                firstPageTask = nil
            }
        }
        do {
            let result = try await task.value
            guard requestRevision == revision, requestQuery == query else {
                return
            }
            let status = result.status
            guard status.availability == .ready else {
                entries = []
                selectedID = nil
                contentState = .unavailable(status.reason)
                pagingState = .complete
                return
            }
            guard let loadedPage = result.page else {
                pagingState = .complete
                return
            }
            totalCount = result.totalCount
            tags = result.tags
            sources = result.sources.map {
                ClipboardHistoryPresentationSource(
                    id: $0.id,
                    bundleID: $0.bundleIdentifier,
                    name: Self.sourceName(for: $0),
                    count: $0.count
                )
            }
            switch loadedPage.state {
            case .ready:
                entries = loadedPage.entries
                nextCursor = loadedPage.nextCursor
                pagingState = loadedPage.nextCursor == nil
                    ? .complete
                    : .moreAvailable
                contentState = entries.isEmpty ? .empty : .content
                reconcileSelection(preferredID: preferredSelection)
                let currentIDs = Set(entries.map(\.id))
                pruneMaterializations { currentIDs.contains($0.entryID) }
            case .indexing:
                entries = []
                selectedID = nil
                nextCursor = nil
                pagingState = .complete
                totalCount = nil
                contentState = .indexing
            case .failed(let failure):
                entries = []
                selectedID = nil
                nextCursor = nil
                pagingState = .complete
                totalCount = nil
                contentState = .unavailable(.searchIndexUnavailable)
                actionFailure = .searchIndexFailed(failure)
            }
        } catch {
            guard requestRevision == revision,
                !(error is CancellationError)
            else {
                return
            }
            entries = []
            selectedID = nil
            nextCursor = nil
            pagingState = .complete
            totalCount = nil
            contentState = .unavailable(nil)
            actionFailure = ClipboardHistoryActionFailure(error)
        }
    }

    private nonisolated static func bestEffortCount(
        _ operations: ClipboardHistoryPresentationOperations,
        _ query: ClipboardHistoryQuery
    ) async -> Int? {
        try? await operations.count(query)
    }

    private func reconcileSelection(
        preferredID: ClipboardHistoryEntryID?
    ) {
        if let preferredID,
            entries.contains(where: { $0.id == preferredID })
        {
            selectedID = preferredID
        } else {
            selectedID = entries.first?.id
        }
    }

    private func invalidateMaterializations(
        for entryID: ClipboardHistoryEntryID
    ) {
        pruneMaterializations { $0.entryID != entryID }
    }

    private func cacheMaterialization(
        _ value: ClipboardHistoryMaterialization,
        for key: MaterializationKey
    ) {
        if materializationCache.updateValue(value, forKey: key) == nil {
            materializationOrder.append(key)
        } else {
            touchMaterialization(key)
        }
        while materializationOrder.count > Self.materializationCacheLimit {
            let evicted = materializationOrder.removeFirst()
            materializationCache.removeValue(forKey: evicted)
        }
    }

    private func touchMaterialization(_ key: MaterializationKey) {
        guard let index = materializationOrder.firstIndex(of: key) else {
            return
        }
        materializationOrder.append(materializationOrder.remove(at: index))
    }

    private func pruneMaterializations(
        keeping isKept: (MaterializationKey) -> Bool
    ) {
        materializationCache = materializationCache.filter { isKept($0.key) }
        materializationOrder.removeAll { !isKept($0) }
    }

    private func upsertTagDefinition(
        _ definition: ClipboardHistoryTagDefinition
    ) {
        if let index = tags.firstIndex(where: {
            $0.id == definition.id
        }) {
            tags[index] = definition
        } else {
            tags.append(definition)
        }
    }

    private func replaceEntry(_ entry: ClipboardHistoryEntry) {
        guard let index = entries.firstIndex(where: {
            $0.id == entry.id
        }) else {
            return
        }
        entries[index] = entry
        invalidateMaterializations(for: entry.id)
    }

    private static func sourceName(
        for summary: ClipboardHistorySourceSummary
    ) -> String {
        switch summary.id {
        case .application(let bundleIdentifier):
            return summary.displayName ?? bundleIdentifier
        case .universalClipboard:
            return L(.clipboardSourceUniversal)
        case .unknown:
            return L(.clipboardSourceUnknown)
        }
    }

    private func decrementSource(_ sourceID: ClipboardHistorySourceID) {
        guard let index = sources.firstIndex(where: {
            $0.id == sourceID
        }) else {
            return
        }
        let source = sources[index]
        if source.count == 1 {
            sources.remove(at: index)
        } else {
            sources[index] = ClipboardHistoryPresentationSource(
                id: source.id,
                bundleID: source.bundleID,
                name: source.name,
                count: source.count - 1
            )
        }
    }
}

/// Everything one first-page load resolves in a single cancellable unit. The
/// count is optional rather than throwing because it is best-effort: it can go
/// missing without invalidating the page it travelled with.
private struct FirstPageResult: Sendable {
    let status: ClipboardHistoryStatus
    let page: ClipboardHistoryPage?
    let tags: [ClipboardHistoryTagDefinition]
    let sources: [ClipboardHistorySourceSummary]
    let totalCount: Int?

    init(
        status: ClipboardHistoryStatus,
        page: ClipboardHistoryPage? = nil,
        tags: [ClipboardHistoryTagDefinition] = [],
        sources: [ClipboardHistorySourceSummary] = [],
        totalCount: Int? = nil
    ) {
        self.status = status
        self.page = page
        self.tags = tags
        self.sources = sources
        self.totalCount = totalCount
    }
}

private struct MaterializationKey: Hashable {
    let entryID: ClipboardHistoryEntryID
    let purpose: MaterializationPurposeKey

    init(
        entryID: ClipboardHistoryEntryID,
        purpose: ClipboardHistoryMaterializationPurpose
    ) {
        self.entryID = entryID
        self.purpose = MaterializationPurposeKey(purpose)
    }
}

private enum MaterializationPurposeKey: Hashable {
    case normalPaste
    case plainTextPaste
    case preview
    case fullPreview
    case hostAction

    init(_ purpose: ClipboardHistoryMaterializationPurpose) {
        switch purpose {
        case .normalPaste:
            self = .normalPaste
        case .plainTextPaste:
            self = .plainTextPaste
        case .preview:
            self = .preview
        case .fullPreview:
            self = .fullPreview
        case .hostAction:
            self = .hostAction
        }
    }
}

private extension ClipboardHistoryMutation {
    var entryID: ClipboardHistoryEntryID {
        switch self {
        case .delete(let entryID),
             .setFavorite(let entryID, _),
             .setTags(let entryID, _),
             .editText(let entryID, _):
            entryID
        }
    }
}
