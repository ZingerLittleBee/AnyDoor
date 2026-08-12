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
    private static let prefetchDistance = 6
    /// A materialization holds the decrypted payload — for an image entry that
    /// is the whole bitmap. Paging is unbounded, so the cache has to be bounded
    /// explicitly or scrolling a long history with previews open grows the
    /// resident set without limit.
    private static let materializationCacheLimit = 16

    private let operations: ClipboardHistoryPresentationOperations
    private var nextCursor: ClipboardHistoryCursor?
    private var revision = 0
    private var isLoadingMore = false
    private var firstPageTask:
        Task<
            (
                ClipboardHistoryStatus,
                ClipboardHistoryPage?,
                [ClipboardHistoryTagDefinition],
                [ClipboardHistorySourceSummary]
            ),
            any Error
        >?
    private var prefetchTask: Task<ClipboardHistoryPage, any Error>?
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

    var canLoadMore: Bool {
        nextCursor != nil
    }

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
            notifyMutation()
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
            notifyMutation()
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
            notifyMutation()
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

    func prefetchIfNeeded(visibleID: ClipboardHistoryEntryID) async {
        guard let index = entries.firstIndex(where: { $0.id == visibleID }),
            index >= max(0, entries.count - Self.prefetchDistance),
            let cursor = nextCursor,
            !isLoadingMore
        else {
            return
        }

        let requestRevision = revision
        let requestQuery = query
        isLoadingMore = true
        let task = Task {
            try await operations.page(requestQuery, cursor)
        }
        prefetchTask = task
        defer {
            if requestRevision == revision {
                isLoadingMore = false
                prefetchTask = nil
            }
        }
        do {
            let page = try await task.value
            guard requestRevision == revision, requestQuery == query else {
                return
            }
            switch page.state {
            case .ready:
                let existingIDs = Set(entries.map(\.id))
                let newEntries = page.entries.filter {
                    !existingIDs.contains($0.id)
                }
                entries.append(contentsOf: newEntries)
                nextCursor = page.nextCursor
                reconcileSelection(preferredID: selectedID)
            case .indexing:
                contentState = .indexing
                nextCursor = nil
            case .failed(let failure):
                actionFailure = .searchIndexFailed(failure)
                nextCursor = nil
            }
        } catch {
            guard requestRevision == revision,
                !(error is CancellationError)
            else {
                return
            }
            actionFailure = ClipboardHistoryActionFailure(error)
        }
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
                notifyMutation()
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
                notifyMutation()
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
        prefetchTask?.cancel()
        prefetchTask = nil
        revision += 1
        let requestRevision = revision
        let preferredSelection = preservingSelection ? selectedID : nil
        let requestQuery = query
        nextCursor = nil
        isLoadingMore = false
        actionFailure = nil
        if entries.isEmpty {
            contentState = .loading
        }

        let task = Task {
            () throws -> (
                ClipboardHistoryStatus,
                ClipboardHistoryPage?,
                [ClipboardHistoryTagDefinition],
                [ClipboardHistorySourceSummary]
            ) in
            let status = await operations.status()
            try Task.checkCancellation()
            guard status.availability == .ready else {
                return (status, nil, [], [])
            }
            async let page = operations.page(requestQuery, nil)
            async let definitions = operations.tagDefinitions()
            async let summaries = operations.sourceSummaries()
            let (loadedPage, loadedTags, loadedSources) = try await (
                page,
                definitions,
                summaries
            )
            try Task.checkCancellation()
            return (status, loadedPage, loadedTags, loadedSources)
        }
        firstPageTask = task
        defer {
            if requestRevision == revision {
                firstPageTask = nil
            }
        }
        do {
            let (status, page, loadedTags, loadedSources) =
                try await task.value
            guard requestRevision == revision, requestQuery == query else {
                return
            }
            guard status.availability == .ready else {
                entries = []
                selectedID = nil
                contentState = .unavailable(status.reason)
                return
            }
            guard let loadedPage = page else {
                return
            }
            tags = loadedTags
            sources = loadedSources.map {
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
                contentState = entries.isEmpty ? .empty : .content
                reconcileSelection(preferredID: preferredSelection)
                let currentIDs = Set(entries.map(\.id))
                pruneMaterializations { currentIDs.contains($0.entryID) }
            case .indexing:
                entries = []
                selectedID = nil
                nextCursor = nil
                contentState = .indexing
            case .failed(let failure):
                entries = []
                selectedID = nil
                nextCursor = nil
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
            contentState = .unavailable(nil)
            actionFailure = ClipboardHistoryActionFailure(error)
        }
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

    private func notifyMutation() {
        NotificationCenter.default.post(
            name: .clipboardHistoryV2DidMutate,
            object: nil
        )
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
    case hostAction

    init(_ purpose: ClipboardHistoryMaterializationPurpose) {
        switch purpose {
        case .normalPaste:
            self = .normalPaste
        case .plainTextPaste:
            self = .plainTextPaste
        case .preview:
            self = .preview
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
