import AppKit
import Foundation
import Observation

struct ImageConversionBasketItem: Identifiable, Equatable, Sendable {
    let url: URL

    var id: String { url.standardizedFileURL.path }
    var name: String { url.lastPathComponent }
    var folderPath: String { url.deletingLastPathComponent().path }
}

@MainActor
@Observable
final class ImageConversionViewModel {
    private(set) var items: [ImageConversionBasketItem] = []
    private(set) var availableFormats: [ImageConversionFormat]
    var selectedFormat: ImageConversionFormat {
        didSet { ImageConversionPreferences.setTargetFormat(selectedFormat, defaults: defaults) }
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
    }

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
            next.append(ImageConversionBasketItem(url: url))
        }
        items = next.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        let fileURLs = items.map(\.url)
        let target = selectedFormat

        Task {
            let summary = await ImageConversionSession().convertAll(
                fileURLs: fileURLs,
                target: target
            )
            finish(summary)
        }
    }

    private func finish(_ summary: ImageConversionSummary) {
        isConverting = false
        if summary.converted > 0 {
            items.removeAll()
            copyOutputsToPasteboard(summary.outputURLs)
        }
        ToastPresenter.shared.show(.success(L(
            .imageConversionToastSummary,
            summary.converted,
            summary.skipped
        )))
    }

    private func copyOutputsToPasteboard(_ outputURLs: [URL]) {
        guard !outputURLs.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(outputURLs as [NSURL])
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
    }
}
