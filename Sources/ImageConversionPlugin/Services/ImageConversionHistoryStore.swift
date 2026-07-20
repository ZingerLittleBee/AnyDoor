import Foundation
import ImageCodec
import Observation
import SwiftData

/// Persists completed Image Conversions and serves one plugin instance's
/// history section. The owning plugin injects its captured `mainContext`, so
/// simultaneously alive plugin instances never overwrite one another's store.
/// Reads no-op and writes report failure when no context is wired (pure tests).
///
/// `@Observable` so a SwiftUI list re-renders when history changes: mutations bump
/// `revision`, which the history view observes to re-fetch — the same "publish a
/// tracked token, re-fetch in body" idiom `TranslationHistoryStore` uses.
@MainActor
@Observable
final class ImageConversionHistoryStore {
    /// Fixed durable cap: the oldest records are trimmed on write so history
    /// never exceeds this many rows.
    static let capacity = 50

    @ObservationIgnored private var modelContext: ModelContext?

    /// Bumped on every write so SwiftUI views tracking it in `body` re-render.
    private(set) var revision: Int = 0

    init(modelContext: ModelContext? = nil) {
        self.modelContext = modelContext
    }

    /// Write one completed conversion and trim to the 50-record cap in the
    /// same save transaction.
    @discardableResult
    func record(
        sourceName: String,
        sourceKind: ImageConversionSourceKind,
        targetFormat: ImageConversionFormat,
        qualityPercent: Int,
        outputPath: String,
        firstFrameOnly: Bool = false,
        createdAt: Date = Date()
    ) -> Bool {
        guard let modelContext else { return false }
        let record = ImageConversionRecord(
            sourceName: sourceName,
            sourceKind: sourceKind,
            targetFormat: targetFormat,
            qualityPercent: qualityPercent,
            outputPath: outputPath,
            createdAt: createdAt
        )
        record.firstFrameOnly = firstFrameOnly
        record.outputByteCount = (try? record.outputURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize).map(Int64.init)
        modelContext.insert(record)
        return saveRecordAndTrim(using: modelContext)
    }

    /// Write one Target Size conversion with its candidate metrics. Called
    /// only when a final file exists (target reached, or an explicit Save
    /// Anyway of a Best-Effort artifact).
    @discardableResult
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
    ) -> Bool {
        guard let modelContext else { return false }
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
        return saveRecordAndTrim(using: modelContext)
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
        savePendingChanges(using: modelContext)
    }

    /// Remove every record (the history header's clear action).
    func clear() {
        guard let modelContext else { return }
        do {
            let rows = try modelContext.fetch(FetchDescriptor<ImageConversionRecord>())
            guard !rows.isEmpty else { return }
            for row in rows { modelContext.delete(row) }
            savePendingChanges(using: modelContext)
        } catch {
            modelContext.rollback()
        }
    }

    private func saveRecordAndTrim(using modelContext: ModelContext) -> Bool {
        do {
            let descriptor = FetchDescriptor<ImageConversionRecord>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let rows = try modelContext.fetch(descriptor)
            if rows.count > Self.capacity {
                for row in rows[Self.capacity...] { modelContext.delete(row) }
            }
            return savePendingChanges(using: modelContext)
        } catch {
            modelContext.rollback()
            return false
        }
    }

    @discardableResult
    private func savePendingChanges(using modelContext: ModelContext) -> Bool {
        do {
            try modelContext.save()
            revision &+= 1
            return true
        } catch {
            modelContext.rollback()
            return false
        }
    }
}
