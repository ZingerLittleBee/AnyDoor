import Foundation
import Observation
import SwiftData

/// Persists successful translations and serves the favorites + history panel.
/// `@MainActor` and context-backed: a single
/// shared `mainContext` is captured in `configure` after the ModelContainer is
/// ready (`TranslationHistoryStore.shared.configure(modelContainer:)` from the
/// app). Every method no-ops when no context is wired (unit tests / pre-bootstrap).
///
/// `@Observable` so a SwiftUI list re-renders when history changes. Reads
/// (`recent`/`favorites`) return live SwiftData fetches; mutations bump
/// `revision`, which the history view observes to refresh its snapshot — the
/// same "publish a tracked token, re-fetch in body" idiom the former clipboard store
/// uses with its `cachedItems`.
@MainActor
@Observable
final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    @ObservationIgnored private var modelContext: ModelContext?

    /// Bumped on every write (record / toggleFavorite / delete / clear / trim).
    /// SwiftUI views read this in `body` so `@Observable` tracks them as
    /// dependents and re-renders when history mutates; the fetch methods are not
    /// stored properties, so observing this token is what drives the refresh.
    private(set) var revision: Int = 0

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    /// Wire the shared container's main context. Mirrors `PanelStore.bootstrap`.
    func configure(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
    }

    /// Write one successful translation. A nil source language (auto-detect that
    /// produced no detection) is stored as an empty code. When `retention > 0`
    /// the durable cap is enforced after the insert by trimming the oldest
    /// non-favorite rows, so history never grows past the configured limit.
    func record(
        sourceText: String,
        translatedText: String,
        source: TranslationLanguage?,
        target: TranslationLanguage,
        serviceID: String,
        serviceName: String,
        runID: String = "",
        retention: Int = 0
    ) {
        guard let modelContext else { return }
        let record = TranslationRecord(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLangCode: source?.code ?? "",
            targetLangCode: target.code,
            serviceID: serviceID,
            serviceName: serviceName,
            runID: runID
        )
        modelContext.insert(record)
        try? modelContext.save()
        // trim() bumps the revision; when retention is unlimited (<= 0) it
        // returns early without bumping, so bump here to cover that path.
        if retention > 0 {
            trim(retention: retention)
        } else {
            revision &+= 1
        }
    }

    /// Newest-first, capped at `limit`.
    func recent(limit: Int) -> [TranslationRecord] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<TranslationRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// All favorited records, newest first.
    func favorites() -> [TranslationRecord] {
        guard let modelContext else { return [] }
        let descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { $0.isFavorite },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func toggleFavorite(_ record: TranslationRecord) {
        guard let modelContext else { return }
        record.isFavorite.toggle()
        try? modelContext.save()
        revision &+= 1
    }

    func delete(_ record: TranslationRecord) {
        guard let modelContext else { return }
        modelContext.delete(record)
        try? modelContext.save()
        revision &+= 1
    }

    /// Set the favorite state of an entire run together (the history card toggles
    /// all of a run's records as one).
    func setFavorite(_ records: [TranslationRecord], to value: Bool) {
        guard let modelContext, !records.isEmpty else { return }
        for record in records { record.isFavorite = value }
        try? modelContext.save()
        revision &+= 1
    }

    /// Delete every record of a run (the history card's trash removes the whole run).
    func delete(_ records: [TranslationRecord]) {
        guard let modelContext, !records.isEmpty else { return }
        for record in records { modelContext.delete(record) }
        try? modelContext.save()
        revision &+= 1
    }

    func clear() {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<TranslationRecord>())) ?? []
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
        revision &+= 1
    }

    /// Keep the newest `retention` non-favorite records; favorites are always
    /// exempt. `retention <= 0` keeps everything (unlimited history).
    func trim(retention: Int) {
        guard let modelContext, retention > 0 else { return }
        let descriptor = FetchDescriptor<TranslationRecord>(
            predicate: #Predicate { !$0.isFavorite },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let nonFavorites = (try? modelContext.fetch(descriptor)) ?? []
        revision &+= 1
        guard nonFavorites.count > retention else { return }
        for row in nonFavorites[retention...] { modelContext.delete(row) }
        try? modelContext.save()
    }
}
