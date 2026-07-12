import Foundation
import SwiftData

/// The V1 terminal outcome recorded for a produced Image Conversion file. Stored
/// as a raw string so it stays portable and survives a lightweight schema change.
enum ImageConversionOutcome: String, Sendable {
    /// A Quality-mode conversion completed at the selected quality.
    case qualityCompleted
    /// A Target Size run produced a file within the Per-Output Limit.
    case targetReached
    /// A Target Size target could not be met; the user explicitly saved the
    /// Best-Effort artifact anyway.
    case targetUnattainable
}

/// One completed Image Conversion, written per successful output when a run
/// finishes. Powers the window's history section. One of the `@Model` types in
/// the app's ModelContainer schema; all fields keep inline scalar defaults so
/// SwiftData lightweight migration can backfill existing stores. No thumbnail is
/// stored — the preview resolves from `outputPath` at render time and degrades to
/// a placeholder when the file is gone.
@Model
final class ImageConversionRecord {
    var id: String = ""
    var createdAt: Date = Date()
    /// The source's display name: a file's last path component, or a generic
    /// label for an in-memory bitmap source.
    var sourceName: String = ""
    /// `ImageConversionSourceKind.rawValue` — whether the source was a file or a
    /// pasted/captured bitmap.
    var sourceKind: String = ""
    /// `ImageConversionFormat.rawValue` of the target encoding.
    var targetFormat: String = ""
    /// Whole-percent quality (1–100) applied to the run. Stays the selected
    /// Quality-mode value and is `0` in Target Size records.
    var qualityPercent: Int = 0
    /// Absolute path of the produced file; the user may delete it independently.
    var outputPath: String = ""

    /// `ImageConversionMode.rawValue` — which strategy produced this record.
    var modeRaw: String = "quality"
    /// `ImageConversionOutcome.rawValue` — the terminal outcome of the run.
    var outcomeRaw: String = "qualityCompleted"
    /// Target Size Per-Output Limit in bytes; `nil` for Quality records.
    var targetByteCount: Int64? = nil
    /// Source file size in bytes; `nil` when not measured.
    var sourceByteCount: Int64? = nil
    /// Produced file size in bytes; `nil` when not measured.
    var outputByteCount: Int64? = nil
    /// Source pixel dimensions; `nil` when not measured.
    var sourcePixelWidth: Int? = nil
    var sourcePixelHeight: Int? = nil
    /// Produced pixel dimensions, reflecting any resize; `nil` when not measured.
    var outputPixelWidth: Int? = nil
    var outputPixelHeight: Int? = nil
    /// Whether Target Size shrank below original dimensions to meet the limit.
    var resizeFallbackApplied: Bool = false
    /// Recorded display downgrade; the only supported value is `"hdrToSDR"`.
    var displayDowngradeRaw: String? = nil
    /// Quality-mode multi-frame/multi-page source converted first-frame-only;
    /// stays `false` for Target Size records.
    var firstFrameOnly: Bool = false

    init(
        sourceName: String,
        sourceKind: ImageConversionSourceKind,
        targetFormat: ImageConversionFormat,
        qualityPercent: Int,
        outputPath: String,
        createdAt: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.createdAt = createdAt
        self.sourceName = sourceName
        self.sourceKind = sourceKind.rawValue
        self.targetFormat = targetFormat.rawValue
        self.qualityPercent = qualityPercent
        self.outputPath = outputPath
    }

    /// The output file's URL, from its stored absolute path.
    var outputURL: URL { URL(fileURLWithPath: outputPath) }

    /// Prefer the immutable metric captured at conversion time. Legacy Quality
    /// records predate that field, so read the current file size as a display
    /// fallback when the output still exists.
    var resolvedOutputByteCount: Int64? {
        if let outputByteCount { return outputByteCount }
        return (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// The conversion mode, decoded from `modeRaw`; an unknown raw string falls
    /// back to `.quality` so a stray value can never leave the UI unbound.
    var mode: ImageConversionMode { ImageConversionMode(rawValue: modeRaw) ?? .quality }

    /// The terminal outcome, decoded from `outcomeRaw`; an unknown raw string
    /// falls back to `.qualityCompleted`.
    var outcome: ImageConversionOutcome {
        ImageConversionOutcome(rawValue: outcomeRaw) ?? .qualityCompleted
    }
}
