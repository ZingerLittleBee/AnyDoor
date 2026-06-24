import Foundation

/// One translation run surfaced as a single history card: all the per-service
/// `TranslationRecord`s that share a `runID`. Legacy rows (empty `runID`) each form
/// their own one-record group.
struct TranslationRunGroup: Identifiable {
    /// Group key: the shared `runID`, or the lone record's own id when `runID` is empty.
    let id: String
    /// This run's records, sorted oldest-first by `createdAt`.
    let records: [TranslationRecord]

    /// The earliest record — its source text and language codes represent the run
    /// (every record in a real run shares them).
    var primary: TranslationRecord { records[0] }
    /// A run is favorited only when every one of its records is.
    var isFavorite: Bool { records.allSatisfy(\.isFavorite) }
    /// The newest timestamp in the run.
    var createdAt: Date { records.map(\.createdAt).max() ?? .distantPast }
}

/// Merge flat history rows into per-run groups. Groups are emitted in the order
/// their key is first seen, so callers passing newest-first rows get newest-first
/// groups. Within each group, records are sorted oldest-first by `createdAt`.
func groupByRun(_ rows: [TranslationRecord]) -> [TranslationRunGroup] {
    var order: [String] = []
    var buckets: [String: [TranslationRecord]] = [:]
    for row in rows {
        let key = row.runID.isEmpty ? row.id : row.runID
        if buckets[key] == nil {
            buckets[key] = []
            order.append(key)
        }
        buckets[key]?.append(row)
    }
    return order.map { key in
        let sorted = (buckets[key] ?? []).sorted { $0.createdAt < $1.createdAt }
        return TranslationRunGroup(id: key, records: sorted)
    }
}
