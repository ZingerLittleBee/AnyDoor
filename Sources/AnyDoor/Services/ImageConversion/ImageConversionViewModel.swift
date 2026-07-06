import AppKit
import Foundation
import Observation

struct ImageConversionBasketItem: Identifiable, Equatable, Sendable {
    /// A basket entry is either an on-disk file (output beside it) or an
    /// in-memory bitmap such as a pasted screenshot (output to Downloads).
    enum Payload: Equatable, Sendable {
        case file(URL)
        case bitmap(Data)
    }

    let id: String
    let payload: Payload
    let displayName: String

    static func file(_ url: URL) -> ImageConversionBasketItem {
        let standardized = url.standardizedFileURL
        return ImageConversionBasketItem(
            id: standardized.path,
            payload: .file(standardized),
            displayName: standardized.lastPathComponent
        )
    }

    static func bitmap(_ data: Data, displayName: String) -> ImageConversionBasketItem {
        ImageConversionBasketItem(
            id: "bitmap:\(UUID().uuidString)",
            payload: .bitmap(data),
            displayName: displayName
        )
    }

    var fileURL: URL? {
        if case let .file(url) = payload { return url }
        return nil
    }

    /// Secondary row line: the source folder for files, empty for bitmaps.
    var subtitle: String {
        fileURL?.deletingLastPathComponent().path ?? ""
    }
}

@MainActor
@Observable
final class ImageConversionViewModel {
    private(set) var items: [ImageConversionBasketItem] = []
    private(set) var availableFormats: [ImageConversionFormat]
    var selectedFormat: ImageConversionFormat {
        didSet { ImageConversionPreferences.setTargetFormat(selectedFormat, defaults: defaults) }
    }
    /// Whole-percent quality (1–100) applied to lossy targets for the whole run.
    var qualityPercent: Int {
        didSet { ImageConversionPreferences.setQualityPercent(qualityPercent, defaults: defaults) }
    }
    var isConverting = false
    var isDropTargeted = false

    @ObservationIgnored private let defaults: UserDefaults

    init(
        availableFormats: [ImageConversionFormat] = ImageConversionFormat.availableTargets(),
        defaults: UserDefaults = .standard
    ) {
        self.availableFormats = availableFormats
        self.defaults = defaults
        self.selectedFormat = ImageConversionPreferences.targetFormat(
            availableFormats: availableFormats,
            defaults: defaults
        )
        self.qualityPercent = ImageConversionPreferences.qualityPercent(defaults: defaults)
    }

    /// The quality slider is only meaningful for lossy targets.
    var isQualityAdjustable: Bool { selectedFormat.isLossy }

    var canConvert: Bool {
        !items.isEmpty && !isConverting && availableFormats.contains(selectedFormat)
    }

    func addFiles(_ urls: [URL]) {
        let imageURLs = urls
            .map { $0.standardizedFileURL }
            .filter { ImageConverter.isImageFile(at: $0) }

        var existing = Set(items.map(\.id))
        var next = items
        for url in imageURLs {
            let key = url.path
            guard existing.insert(key).inserted else { continue }
            next.append(.file(url))
        }
        items = next.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Adds a pasted bitmap (e.g. a fresh screenshot) with a generic display name.
    func addBitmap(_ data: Data) {
        items.append(.bitmap(data, displayName: L(.imageConversionClipboardItem)))
    }

    func remove(_ item: ImageConversionBasketItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    func convert() {
        guard canConvert else { return }
        isConverting = true
        let inputs: [ImageConversionInput] = items.map { item in
            switch item.payload {
            case let .file(url): return .file(url)
            case let .bitmap(data): return .bitmap(data)
            }
        }
        let target = selectedFormat
        let quality = Double(qualityPercent) / 100.0

        Task {
            let summary = await ImageConversionSession().convertAll(
                inputs: inputs,
                target: target,
                quality: quality,
                downloadsDirectory: ImageConversionSession.defaultDownloadsDirectory
            )
            finish(summary)
        }
    }

    private func finish(_ summary: ImageConversionSummary) {
        isConverting = false
        if summary.converted > 0 {
            recordHistory(summary.outputs)
            items.removeAll()
            copyOutputsToPasteboard(summary.outputURLs)
        }
        ToastPresenter.shared.show(.success(L(
            .imageConversionToastSummary,
            summary.converted,
            summary.skipped
        )))
    }

    /// Write one Conversion Record per produced output. The target format and
    /// quality are the whole run's config (one config per run).
    private func recordHistory(_ outputs: [ImageConversionOutput]) {
        let target = selectedFormat
        let quality = qualityPercent
        for output in outputs {
            ImageConversionHistoryStore.shared.record(
                sourceName: output.sourceName,
                sourceKind: output.sourceKind,
                targetFormat: target,
                qualityPercent: quality,
                outputPath: output.outputURL.path
            )
        }
    }

    private func copyOutputsToPasteboard(_ outputURLs: [URL]) {
        guard !outputURLs.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(outputURLs as [NSURL])
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
    }
}
