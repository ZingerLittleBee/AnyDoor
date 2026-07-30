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
    let replaceTagDefinitions:
        @Sendable (
            Set<String>
        ) async throws -> ClipboardHistoryTagDefinitionUpdate

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
        replaceTagDefinitions = { tagIDs in
            try await module.replaceTagDefinitions(with: tagIDs)
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
        replaceTagDefinitions:
            @escaping @Sendable (
                Set<String>
            ) async throws -> ClipboardHistoryTagDefinitionUpdate = { _ in
                ClipboardHistoryTagDefinitionUpdate(
                    removedMembershipCount: 0,
                    unprotectedEntryCount: 0
                )
            }
    ) {
        self.status = status
        self.page = page
        self.apply = apply
        self.materialize = materialize
        self.tagDefinitions = tagDefinitions
        self.replaceTagDefinitions = replaceTagDefinitions
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
    let bundleID: String
    let name: String
    let count: Int

    var id: String { bundleID }
}

enum ClipboardHistoryActionFailure: Equatable {
    case operationUnavailable
    case entryNotFound
    case storeUnavailable
    case storageFailure
    case payloadAuthenticationFailed
    case payloadUnavailable
    case fileReferencesUnavailable(count: Int)
    case fileCollectionRequiresRestore(
        ownedCount: Int,
        unavailableCount: Int
    )
    case invalidTagIDs
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
        case .fileReferencesUnavailable(_, let count):
            self = .fileReferencesUnavailable(count: count)
        case .fileCollectionRequiresRestore(
            _,
            let ownedCount,
            let unavailableCount
        ):
            self = .fileCollectionRequiresRestore(
                ownedCount: ownedCount,
                unavailableCount: unavailableCount
            )
        case .invalidTagIDs:
            self = .invalidTagIDs
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

    private let operations: ClipboardHistoryPresentationOperations
    private var nextCursor: ClipboardHistoryCursor?
    private var revision = 0
    private var isLoadingMore = false
    private var materializationCache:
        [MaterializationKey: ClipboardHistoryMaterialization] = [:]
    private var sourceNames: [String: String] = [:]
    private var sourceEntryIDs:
        [String: Set<ClipboardHistoryEntryID>] = [:]

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

    func replaceTagDefinitions(with tagIDs: Set<String>) async -> Bool {
        actionFailure = nil
        do {
            _ = try await operations.replaceTagDefinitions(tagIDs)
            tags = try await operations.tagDefinitions()
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
        defer {
            if requestRevision == revision {
                isLoadingMore = false
            }
        }
        do {
            let page = try await operations.page(requestQuery, cursor)
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
                mergeSources(from: newEntries)
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
            guard requestRevision == revision else { return }
            actionFailure = ClipboardHistoryActionFailure(error)
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
                mergeSources(from: [entry])
                invalidateMaterializations(for: entry.id)
            case .deleted, .notFound:
                let entryID = mutation.entryID
                let deletedIndex = entries.firstIndex { $0.id == entryID }
                entries.removeAll { $0.id == entryID }
                removeSourceEntry(entryID)
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
                materializationCache[key] = value
            }
            return value
        } catch {
            if recordsFailure {
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

        let status = await operations.status()
        guard requestRevision == revision else { return }
        guard status.availability == .ready else {
            entries = []
            selectedID = nil
            contentState = .unavailable(status.reason)
            return
        }

        do {
            async let page = operations.page(requestQuery, nil)
            async let definitions = operations.tagDefinitions()
            let (loadedPage, loadedTags) = try await (page, definitions)
            guard requestRevision == revision, requestQuery == query else {
                return
            }
            tags = loadedTags
            switch loadedPage.state {
            case .ready:
                entries = loadedPage.entries
                if requestQuery == ClipboardHistoryQuery() {
                    sourceNames = [:]
                    sourceEntryIDs = [:]
                }
                mergeSources(from: loadedPage.entries)
                nextCursor = loadedPage.nextCursor
                contentState = entries.isEmpty ? .empty : .content
                reconcileSelection(preferredID: preferredSelection)
                let currentIDs = Set(entries.map(\.id))
                materializationCache = materializationCache.filter {
                    currentIDs.contains($0.key.entryID)
                }
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
            guard requestRevision == revision else { return }
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
        materializationCache = materializationCache.filter {
            $0.key.entryID != entryID
        }
    }

    private func mergeSources(from entries: [ClipboardHistoryEntry]) {
        for entry in entries {
            guard let bundleID = entry.source.bundleIdentifier else {
                continue
            }
            sourceNames[bundleID] =
                entry.source.displayName ?? bundleID
            sourceEntryIDs[bundleID, default: []].insert(entry.id)
        }
        rebuildSources()
    }

    private func removeSourceEntry(_ entryID: ClipboardHistoryEntryID) {
        for bundleID in Array(sourceEntryIDs.keys) {
            sourceEntryIDs[bundleID]?.remove(entryID)
            if sourceEntryIDs[bundleID]?.isEmpty == true {
                sourceEntryIDs.removeValue(forKey: bundleID)
                sourceNames.removeValue(forKey: bundleID)
            }
        }
        rebuildSources()
    }

    private func rebuildSources() {
        sources = sourceEntryIDs.compactMap { bundleID, entryIDs in
            guard !entryIDs.isEmpty else { return nil }
            return ClipboardHistoryPresentationSource(
                bundleID: bundleID,
                name: sourceNames[bundleID] ?? bundleID,
                count: entryIDs.count
            )
        }
        .sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                == .orderedAscending
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
