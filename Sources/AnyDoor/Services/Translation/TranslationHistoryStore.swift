import Foundation
import SwiftData

/// Persists successful translations and serves the favorites + history panel.
/// `@MainActor` and context-backed, mirroring `ClipboardHistoryStore`: a single
/// shared `mainContext` is captured in `configure` after the ModelContainer is
/// ready (`TranslationHistoryStore.shared.configure(modelContainer:)` from the
/// app). Every method no-ops when no context is wired (unit tests / pre-bootstrap).
@MainActor
final class TranslationHistoryStore {
    static let shared = TranslationHistoryStore()

    private var modelContext: ModelContext?

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
        retention: Int = 0
    ) {
        guard let modelContext else { return }
        let record = TranslationRecord(
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLangCode: source?.code ?? "",
            targetLangCode: target.code,
            serviceID: serviceID,
            serviceName: serviceName
        )
        modelContext.insert(record)
        try? modelContext.save()
        trim(retention: retention)
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
    }

    func delete(_ record: TranslationRecord) {
        guard let modelContext else { return }
        modelContext.delete(record)
        try? modelContext.save()
    }

    func clear() {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<TranslationRecord>())) ?? []
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
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
        guard nonFavorites.count > retention else { return }
        for row in nonFavorites[retention...] { modelContext.delete(row) }
        try? modelContext.save()
    }
}
