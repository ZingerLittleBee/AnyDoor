import Foundation
import Observation
import SwiftData

/// Persists completed Image Conversions and serves the window's history section.
/// `@MainActor` and context-backed, mirroring `TranslationHistoryStore`: a single
/// shared `mainContext` is captured in `configure` after the ModelContainer is
/// ready (`ImageConversionHistoryStore.shared.configure(modelContainer:)` from the
/// app). Every method no-ops when no context is wired (unit tests / pre-bootstrap).
///
/// `@Observable` so a SwiftUI list re-renders when history changes: mutations bump
/// `revision`, which the history view observes to re-fetch — the same "publish a
/// tracked token, re-fetch in body" idiom `TranslationHistoryStore` uses.
@MainActor
@Observable
final class ImageConversionHistoryStore {
    static let shared = ImageConversionHistoryStore()

    /// Fixed durable cap: the oldest records are trimmed on write so history
    /// never exceeds this many rows.
    static let capacity = 50

    @ObservationIgnored private var modelContext: ModelContext?

    /// Bumped on every write so SwiftUI views tracking it in `body` re-render.
    private(set) var revision: Int = 0

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    /// Wire the shared container's main context. Mirrors `TranslationHistoryStore.configure`.
    func configure(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
    }

    /// Write one completed conversion, then trim to the 50-record cap.
    func record(
        sourceName: String,
        sourceKind: ImageConversionSourceKind,
        targetFormat: ImageConversionFormat,
        qualityPercent: Int,
        outputPath: String,
        createdAt: Date = Date()
    ) {
        guard let modelContext else { return }
        let record = ImageConversionRecord(
            sourceName: sourceName,
            sourceKind: sourceKind,
            targetFormat: targetFormat,
            qualityPercent: qualityPercent,
            outputPath: outputPath,
            createdAt: createdAt
        )
        modelContext.insert(record)
        try? modelContext.save()
        trim()
        revision &+= 1
    }

    /// Write one Target Size conversion with its candidate metrics. Called
    /// only when a final file exists (target reached, or an explicit Save
    /// Anyway of a Best-Effort artifact).
    func recordTargetSize(
        sourceName: String,
        sourceKind: ImageConversionSourceKind,
        targetFormat: ImageConversionFormat,
        outputPath: String,
        outcome: ImageConversionOutcome,
        targetByteCount: Int64,
        candidate: PreparedCandidate,
        outputByteCount: Int64,
        createdAt: Date = Date()
    ) {
        guard let modelContext else { return }
        let record = ImageConversionRecord(
            sourceName: sourceName,
            sourceKind: sourceKind,
            targetFormat: targetFormat,
            qualityPercent: 0,
            outputPath: outputPath,
            createdAt: createdAt
        )
        record.modeRaw = ImageConversionMode.targetSize.rawValue
        record.outcomeRaw = outcome.rawValue
        record.targetByteCount = targetByteCount
        record.sourceByteCount = candidate.sourceByteCount
        record.outputByteCount = outputByteCount
        record.sourcePixelWidth = candidate.sourceDimensions.width
        record.sourcePixelHeight = candidate.sourceDimensions.height
        record.outputPixelWidth = candidate.dimensions.width
        record.outputPixelHeight = candidate.dimensions.height
        record.resizeFallbackApplied = candidate.resizeFallbackApplied
        record.displayDowngradeRaw = candidate.hdrToSDR ? "hdrToSDR" : nil
        modelContext.insert(record)
        try? modelContext.save()
        trim()
        revision &+= 1
    }

    /// Newest-first, capped at `limit`.
    func recent(limit: Int = capacity) -> [ImageConversionRecord] {
        guard let modelContext else { return [] }
        var descriptor = FetchDescriptor<ImageConversionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = max(0, limit)
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func delete(_ record: ImageConversionRecord) {
        guard let modelContext else { return }
        modelContext.delete(record)
        try? modelContext.save()
        revision &+= 1
    }

    /// Remove every record (the history header's clear action).
    func clear() {
        guard let modelContext else { return }
        let rows = (try? modelContext.fetch(FetchDescriptor<ImageConversionRecord>())) ?? []
        guard !rows.isEmpty else { return }
        for row in rows { modelContext.delete(row) }
        try? modelContext.save()
        revision &+= 1
    }

    /// Keep the newest `capacity` records, deleting the overflow oldest.
    private func trim() {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<ImageConversionRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        guard rows.count > Self.capacity else { return }
        for row in rows[Self.capacity...] { modelContext.delete(row) }
        try? modelContext.save()
    }
}
