import Foundation
import SwiftData

/// One completed Image Conversion, written per successful output when a run
/// finishes. Powers the window's history section. The sixth `@Model` in the
/// app's ModelContainer schema; all fields keep inline scalar defaults so
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
    /// Whole-percent quality (1–100) applied to the run.
    var qualityPercent: Int = 0
    /// Absolute path of the produced file; the user may delete it independently.
    var outputPath: String = ""

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
}
