import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageConversionView: View {
    @Bindable var model: ImageConversionViewModel
    var store: ImageConversionHistoryStore = .shared

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if model.items.isEmpty {
                    emptyState
                } else {
                    basketList
                }
                if model.isDropTargeted {
                    dropOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            historySection
        }
        .adaptivePanelSurface(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Fill the whole window: without this the hosting view treats the
        // transparent titlebar as a safe-area inset and the card gets pushed
        // below it, leaving an invisible-but-draggable strip above the card
        // with the traffic light floating in it.
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted, perform: handleDrop)
        .focusEffectDisabled()
    }

    // Two rows: the first shares the traffic-light line — AppKit draws the
    // buttons over the card's top-left, the title sits beside them and the
    // actions right-align; the second row carries the conversion config,
    // right-aligned. Splitting also keeps the long English labels from
    // hyphen-wrapping the title in one row.
    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                LocalizedText(.imageConversionTitle)
                    .font(.headline)
                    .lineLimit(1)
                    // Clear the three traffic lights overlaying the card's
                    // top-left corner (their rightmost edge is ≈61pt from the
                    // window edge; the toolbar already pads 16pt).
                    .padding(.leading, 70)
                Spacer()
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(model.items.isEmpty || model.isConverting)
                .accessibilityLabel(L(.imageConversionClear))
                .help(L(.imageConversionClear))

                Button {
                    model.convert()
                } label: {
                    HStack(spacing: 6) {
                        if model.isConverting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(L(model.isConverting ? .imageConversionConverting : .imageConversionConvert))
                    }
                    .frame(minWidth: 86)
                }
                .disabled(!model.canConvert)
            }

            HStack(spacing: 14) {
                if model.isQualityAdjustable {
                    qualityControl
                }
                Spacer()
                if model.availableFormats.isEmpty {
                    LocalizedText(.imageConversionNoFormats)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        LocalizedText(.imageConversionTargetFormat)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(L(.imageConversionTargetFormat), selection: $model.selectedFormat) {
                            ForEach(model.availableFormats) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        .labelsHidden()
                        // Trailing-aligned inside the fixed slot so the popup's
                        // right edge lines up with the Convert button above.
                        .frame(width: 112, alignment: .trailing)
                    }
                    .help(L(.imageConversionTargetFormat))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var qualityControl: some View {
        HStack(spacing: 6) {
            LocalizedText(.imageConversionQuality)
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(model.qualityPercent) },
                    set: { model.qualityPercent = Int($0.rounded()) }
                ),
                in: Double(ImageConversionPreferences.minQualityPercent)...Double(ImageConversionPreferences.maxQualityPercent)
            )
            .controlSize(.small)
            .frame(width: 96)
            Text("\(model.qualityPercent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L(.imageConversionQuality))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.stack")
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(.secondary)
            LocalizedText(.imageConversionDropTitle)
                .font(.headline)
            LocalizedText(.imageConversionDropSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(28)
    }

    private var basketList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L(.imageConversionBasketCount, model.items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.items) { item in
                        ImageConversionRow(item: item) {
                            model.remove(item)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            )
            .overlay {
                LocalizedText(.imageConversionDropTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            .padding(14)
    }

    // Reading `store.revision` here (during body evaluation) establishes an
    // @Observable dependency so the section re-fetches on every store write —
    // the same idiom `TranslationHistoryView` uses.
    private var historySection: some View {
        _ = store.revision
        let records = store.recent()
        return VStack(spacing: 0) {
            Divider()
            HStack {
                LocalizedText(.imageConversionHistoryTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(records.isEmpty)
                .accessibilityLabel(L(.imageConversionHistoryClear))
                .help(L(.imageConversionHistoryClear))
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if records.isEmpty {
                historyEmpty
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(records, id: \.id) { record in
                            ImageConversionHistoryRow(record: record)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(height: 168)
    }

    private var historyEmpty: some View {
        VStack {
            Spacer()
            LocalizedText(.imageConversionHistoryEmpty)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = ImageConversionDropSupport.url(from: item) else { return }
                Task { @MainActor in
                    model.addFiles([url])
                }
            }
        }
        return accepted
    }
}

private struct ImageConversionRow: View {
    let item: ImageConversionBasketItem
    let remove: () -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: resolvedThumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.imageConversionRemove))
            .help(L(.imageConversionRemove))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: item.id) {
            thumbnail = await loadThumbnail()
        }
    }

    /// Async-decoded image preview, with a synchronous cache fast path for file
    /// items and a file-type icon while the decode is in flight.
    private var resolvedThumbnail: NSImage {
        if let thumbnail { return thumbnail }
        if let url = item.fileURL {
            return ClipboardThumbnail.cached(at: url) ?? NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .image)
    }

    private func loadThumbnail() async -> NSImage? {
        switch item.payload {
        case .file(let url):
            return await ClipboardThumbnail.thumbnail(at: url)
        case .bitmap(let data):
            return await BitmapThumbnail.decode(data)
        }
    }
}

/// Downsampled thumbnails for in-memory bitmap basket items — the Data twin of
/// `ClipboardThumbnail`, without a cache (bitmap items are few and short-lived).
private enum BitmapThumbnail {
    /// Carries the non-Sendable `NSImage` produced off-main back to the main
    /// actor. `@unchecked` is sound because the image is freshly created in the
    /// detached task and never mutated afterwards — only read while drawing.
    private struct SendableImage: @unchecked Sendable {
        let image: NSImage
    }

    static func decode(_ data: Data) async -> NSImage? {
        let task = Task.detached(priority: .userInitiated) { () -> SendableImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return SendableImage(image: NSImage(cgImage: cgImage, size: .zero))
        }
        return await task.value?.image
    }
}

private struct ImageConversionHistoryRow: View {
    let record: ImageConversionRecord
    @State private var preview: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: resolvedPreview)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(record.sourceName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(record.targetFormat.uppercased())
                    Text(record.createdAt, style: .relative)
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: reveal) {
                Image(systemName: "folder")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.clipboardActionRevealInFinder))
            .help(L(.clipboardActionRevealInFinder))

            Button(action: copyAsFile) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.imageConversionCopyAsFile))
            .help(L(.imageConversionCopyAsFile))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: record.outputPath) {
            guard FileManager.default.fileExists(atPath: record.outputPath) else { return }
            preview = await ClipboardThumbnail.thumbnail(at: record.outputURL)
        }
    }

    /// Resolves the preview from the output path at render time (downsampled and
    /// cached via `ClipboardThumbnail`); a deleted file degrades to a generic
    /// placeholder rather than a broken image.
    private var resolvedPreview: NSImage {
        if let preview { return preview }
        if let cached = ClipboardThumbnail.cached(at: record.outputURL) { return cached }
        return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .image)
    }

    /// Selects the output in Finder; a missing file shows a toast instead of a
    /// broken reveal.
    private func reveal() {
        let url = record.outputURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastPresenter.shared.show(.failure(L(.imageConversionFileMissing)))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Puts the output on the pasteboard as a file URL (with self-write
    /// suppression so AnyDoor's own clipboard history ignores it), ready to paste.
    private func copyAsFile() {
        let url = record.outputURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastPresenter.shared.show(.failure(L(.imageConversionFileMissing)))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}

private enum ImageConversionDropSupport {
    static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        return nil
    }
}
