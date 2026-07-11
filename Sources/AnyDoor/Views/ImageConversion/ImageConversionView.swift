import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct ImageConversionView: View {
    @Bindable var model: ImageConversionViewModel
    var store: ImageConversionHistoryStore = .shared

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            Divider()
            ZStack {
                HStack(spacing: 0) {
                    sidebar
                    Divider()
                    workspaceColumn
                }
                if model.isDropTargeted {
                    dropOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .adaptivePanelSurface(cornerRadius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The content extends under the transparent title bar so the traffic
        // lights sit inside the title row rather than above the panel surface.
        .ignoresSafeArea()
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted, perform: handleDrop)
    }

    private var titleRow: some View {
        HStack(spacing: 10) {
            LocalizedText(.imageConversionTitle)
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 70)
            Spacer()
            if model.isConverting {
                ProgressView()
                    .controlSize(.small)
                LocalizedText(.imageConversionConverting)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.sidebarTab) {
                LocalizedText(.imageConversionSidebarBasket).tag(ImageConversionSidebarTab.basket)
                LocalizedText(.imageConversionHistoryTitle).tag(ImageConversionSidebarTab.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch model.sidebarTab {
            case .basket:
                basketSidebar
            case .history:
                historySidebar
            }
        }
        .frame(width: 220)
        .background(.regularMaterial)
    }

    private var basketSidebar: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyBasket
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(model.items) { item in
                            ImageConversionSidebarRow(
                                item: item,
                                status: model.itemStatuses[item.id],
                                showsFirstFrameOnly: model.mode == .quality
                                    && model.qualityFirstFrameOnlyItemIDs.contains(item.id),
                                isSelected: model.selectedItemID == item.id,
                                isRemovalDisabled: model.isConverting,
                                select: { model.selectedItemID = item.id },
                                remove: { model.remove(item) }
                            )
                        }
                    }
                    .padding(8)
                }
            }

            Text(L(.imageConversionBasketCount, model.items.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.presentOpenPanel()
                } label: {
                    Label(L(.commandPaletteActionOpen), systemImage: "plus")
                        .lineLimit(1)
                }
                .disabled(model.isConverting)
                .help(L(.commandPaletteActionOpen))

                Spacer(minLength: 0)

                Button {
                    model.clear()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(model.items.isEmpty || model.isConverting)
                .accessibilityLabel(L(.imageConversionClear))
                .help(L(.imageConversionClear))
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    private var emptyBasket: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            LocalizedText(.imageConversionDropTitle)
                .font(.caption.weight(.medium))
            LocalizedText(.imageConversionDropSubtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Reading `store.revision` during body evaluation establishes the
    // observation dependency that makes this fetched list update after writes.
    private var historySidebar: some View {
        _ = store.revision
        let records = store.recent()
        return VStack(spacing: 0) {
            if records.isEmpty {
                VStack {
                    Spacer()
                    LocalizedText(.imageConversionHistoryEmpty)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(records, id: \.id) { record in
                            ImageConversionHistoryRow(record: record)
                        }
                    }
                    .padding(8)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button {
                    store.clear()
                } label: {
                    Label(L(.imageConversionHistoryClear), systemImage: "trash")
                }
                .disabled(records.isEmpty)
            }
            .controlSize(.small)
            .padding(10)
        }
    }

    // MARK: - Workspace (comparison + bottom control bar)

    /// The main column right of the sidebar: the full-width comparison on
    /// top, an optional target-miss banner, and the control bar at the
    /// bottom (the former right-hand inspector, flattened into one strip so
    /// the comparison gets all the width).
    private var workspaceColumn: some View {
        VStack(spacing: 0) {
            comparisonWorkspace
            if let item = model.selectedItem,
               case .targetMiss(let candidate) = model.itemStatuses[item.id] {
                Divider()
                targetMissBanner(candidate, item: item)
            }
            Divider()
            controlBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comparisonWorkspace: some View {
        HStack(spacing: 0) {
            comparisonPane(title: .imageConversionCompareOriginal) {
                originalPreview
            }
            Divider()
            comparisonPane(title: .imageConversionCompareResult) {
                resultPreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func comparisonPane<Content: View>(
        title: L10n.Key,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            LocalizedText(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: 36)
            Divider()
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var originalPreview: some View {
        if let item = model.selectedItem {
            ImageComparisonPreview(source: .basket(item))
        } else {
            comparisonMessage(.imageConversionCompareEmpty)
        }
    }

    @ViewBuilder
    private var resultPreview: some View {
        switch model.previewState {
        case .empty:
            comparisonMessage(.imageConversionCompareEmpty)
        case .updating:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                LocalizedText(.imageConversionCompareUpdating)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .ready(let candidate):
            ImageComparisonPreview(
                source: .file(candidate.artifact.artifactURL),
                caption: ComparisonCaption(
                    byteCount: candidate.artifact.byteCount,
                    dimensions: candidate.dimensions
                ),
                showsBestEffortBadge: candidate.isBestEffort
            )
        case .readyQuality(let preview):
            // The caption self-computes from the encoded bytes.
            ImageComparisonPreview(source: .bitmap(id: preview.id, data: preview.data))
        case .unsupported(let issue):
            let key: L10n.Key = switch issue {
            case .sourceMissing: .imageConversionSourceMissing
            case .targetSizeUnsupportedFormat: .imageConversionStatusUnsupportedFormat
            default: .imageConversionStatusUnsupported
            }
            comparisonMessage(key)
        case .invalidConfiguration:
            comparisonMessage(.imageConversionTargetInvalid)
        case .failed:
            comparisonMessage(.imageConversionStatusFailed)
        }
    }

    private func comparisonMessage(_ key: L10n.Key) -> some View {
        LocalizedText(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Top row: only the active mode's own controls.
            HStack(spacing: 14) {
                if model.mode == .quality {
                    qualityModeControls
                } else {
                    targetSizeModeControls
                }

                Group {
                    if model.mode == .targetSize {
                        LocalizedText(.imageConversionTargetSizeSameFormat)
                        Text("·")
                        LocalizedText(.imageConversionTargetSizePNGNote)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                Spacer(minLength: 0)
            }
            .disabled(model.isConverting)
            // Both modes' controls resolve to slightly different intrinsic
            // heights; pin the row so the mode switch cannot move the bar.
            .frame(minHeight: 28)

            // Bottom row: mode switch on the left, primary action pinned to
            // the trailing edge.
            HStack(spacing: 14) {
                Picker("", selection: $model.mode) {
                    LocalizedText(.imageConversionModeFormat).tag(ImageConversionMode.quality)
                    LocalizedText(.imageConversionModeTargetSize).tag(ImageConversionMode.targetSize)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(model.isConverting)

                Spacer(minLength: 12)

                primaryAction
                    .frame(width: 132)
            }
            .frame(minHeight: 28)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var qualityModeControls: some View {
        if model.availableFormats.isEmpty {
            LocalizedText(.imageConversionNoFormats)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker(L(.imageConversionTargetFormat), selection: $model.selectedFormat) {
                ForEach(model.availableFormats) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .labelsHidden()
            .fixedSize()

            if model.isQualityAdjustable {
                HStack(spacing: 8) {
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
                    .frame(width: 170)
                    Text("\(model.qualityPercent)%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L(.imageConversionQuality))
            }
        }
    }

    private var targetSizeModeControls: some View {
        HStack(spacing: 8) {
            TextField("1", text: $model.targetText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onSubmit { model.commitTargetText() }
                .onChange(of: model.targetText) { model.commitTargetText() }
                .accessibilityLabel(L(.imageConversionModeTargetSize))
            Picker("", selection: Binding(
                get: { model.targetLimit.unit },
                set: { model.switchTargetUnit(to: $0) }
            )) {
                Text("KB").tag(TargetSizeUnit.kb)
                Text("MB").tag(TargetSizeUnit.mb)
            }
            .labelsHidden()
            .fixedSize()

            if model.targetParseError != nil {
                LocalizedText(.imageConversionTargetInvalid)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
    }

    /// Compact strip between the comparison and the control bar for the
    /// selected item's retained Best-Effort miss: status, metrics, and the
    /// explicit Save Anyway commit.
    private func targetMissBanner(
        _ candidate: PreparedCandidate,
        item: ImageConversionBasketItem
    ) -> some View {
        HStack(spacing: 10) {
            LocalizedText(.imageConversionStatusTargetMiss)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            LocalizedText(.imageConversionUnattainableHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(candidate.caption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.saveBestEffort(item)
            } label: {
                LocalizedText(.imageConversionSaveAnyway)
            }
            .controlSize(.small)
            .disabled(model.isConverting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private var primaryAction: some View {
        if model.isConverting {
            Button {
                model.stopConversion()
            } label: {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    LocalizedText(.imageConversionStop)
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            Button {
                model.convert()
            } label: {
                HStack(spacing: 8) {
                    if model.isConverting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    LocalizedText(model.isConverting
                        ? .imageConversionConverting
                        : .imageConversionConvertAll)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canConvert)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            )
            .overlay {
                LocalizedText(.imageConversionDropTitle)
                    .font(.headline)
            }
            .padding(14)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isConverting else { return false }
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

private struct ImageConversionSidebarRow: View {
    let item: ImageConversionBasketItem
    var status: ImageConversionItemStatus?
    var showsFirstFrameOnly: Bool
    var isSelected: Bool
    var isRemovalDisabled: Bool
    let select: () -> Void
    let remove: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: resolvedThumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            Text(item.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            statusBadge

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(isRemovalDisabled)
            .accessibilityLabel(L(.imageConversionRemove))
            .help(L(.imageConversionRemove))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            isSelected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .task(id: item.id) {
            thumbnail = await loadThumbnail()
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .targetMiss:
            badge(L(.imageConversionStatusTargetMiss), color: .orange)
        case .unsupported:
            badge(L(.imageConversionStatusUnsupported), color: .secondary)
        case .failed:
            badge(L(.imageConversionStatusFailed), color: .red)
        case nil:
            if showsFirstFrameOnly {
                badge(L(.imageConversionStatusFirstFrameOnly), color: .secondary)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

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

private struct ComparisonCaption: Hashable, Sendable {
    var byteCount: Int64?
    var dimensions: PixelDimensions

    var text: String {
        let dimensionsText = "\(dimensions.width) × \(dimensions.height)"
        guard let byteCount else { return dimensionsText }
        return "\(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) · \(dimensionsText)"
    }
}

private enum ImageComparisonSource: Hashable, Sendable {
    case file(URL)
    case bitmap(id: String, data: Data)

    static func basket(_ item: ImageConversionBasketItem) -> ImageComparisonSource {
        switch item.payload {
        case .file(let url):
            return .file(url)
        case .bitmap(let data):
            return .bitmap(id: item.id, data: data)
        }
    }
}

private struct ImageComparisonPreview: View {
    let source: ImageComparisonSource
    var caption: ComparisonCaption?
    var showsBestEffortBadge = false

    @State private var loaded: ComparisonImageLoader.LoadedImage?
    @State private var didFail = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let loaded {
                    Image(nsImage: loaded.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                } else if didFail {
                    LocalizedText(.imageConversionSourceMissing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let resolvedCaption {
                Divider()
                HStack(spacing: 8) {
                    Text(resolvedCaption.text)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if showsBestEffortBadge {
                        Text(L(.imageConversionStatusTargetMiss))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
            }
        }
        .task(id: source) {
            loaded = nil
            didFail = false
            let image = await ComparisonImageLoader.load(source)
            guard !Task.isCancelled else { return }
            loaded = image
            didFail = image == nil
        }
    }

    private var resolvedCaption: ComparisonCaption? {
        caption ?? loaded?.caption
    }
}

private enum ComparisonImageLoader {
    /// The image is created once in the detached decode and is immutable after
    /// crossing back to the main actor, matching the thumbnail cache invariant.
    struct LoadedImage: @unchecked Sendable {
        let image: NSImage
        let caption: ComparisonCaption
    }

    static func load(
        _ source: ImageComparisonSource,
        maxPixelSize: Int = 2_560
    ) async -> LoadedImage? {
        let task = Task.detached(priority: .userInitiated) {
            decode(source, maxPixelSize: maxPixelSize)
        }
        return await task.value
    }

    private nonisolated static func decode(
        _ input: ImageComparisonSource,
        maxPixelSize: Int
    ) -> LoadedImage? {
        let source: CGImageSource
        let byteCount: Int64?
        switch input {
        case .file(let url):
            guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            source = imageSource
            byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        case .bitmap(_, let data):
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            source = imageSource
            byteCount = Int64(data.count)
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0 else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return LoadedImage(
            image: NSImage(cgImage: cgImage, size: .zero),
            caption: ComparisonCaption(
                byteCount: byteCount,
                dimensions: PixelDimensions(width: width, height: height)
            )
        )
    }
}

private extension PreparedCandidate {
    var isBestEffort: Bool {
        if case .bestEffort = kind { return true }
        return false
    }

    var caption: String {
        ComparisonCaption(byteCount: artifact.byteCount, dimensions: dimensions).text
    }
}

/// Downsampled thumbnails for in-memory bitmap basket items. The Data payload
/// is short-lived, so no cache is needed.
private enum BitmapThumbnail {
    static func decode(_ data: Data) async -> NSImage? {
        await ComparisonImageLoader.load(
            .bitmap(id: "thumbnail", data: data),
            maxPixelSize: 96
        )?.image
    }
}

private struct ImageConversionHistoryRow: View {
    let record: ImageConversionRecord
    @State private var preview: NSImage?

    var body: some View {
        HStack(spacing: 8) {
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
            Spacer(minLength: 0)
            Button(action: reveal) {
                Image(systemName: "folder")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.clipboardActionRevealInFinder))
            .help(L(.clipboardActionRevealInFinder))

            Button(action: copyAsFile) {
                Image(systemName: "doc.on.doc")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L(.imageConversionCopyAsFile))
            .help(L(.imageConversionCopyAsFile))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .task(id: record.outputPath) {
            guard FileManager.default.fileExists(atPath: record.outputPath) else { return }
            preview = await ClipboardThumbnail.thumbnail(at: record.outputURL)
        }
    }

    private var resolvedPreview: NSImage {
        if let preview { return preview }
        if let cached = ClipboardThumbnail.cached(at: record.outputURL) { return cached }
        return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            ?? NSWorkspace.shared.icon(for: .image)
    }

    private func reveal() {
        let url = record.outputURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastPresenter.shared.show(.failure(L(.imageConversionFileMissing)))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyAsFile() {
        let url = record.outputURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            ToastPresenter.shared.show(.failure(L(.imageConversionFileMissing)))
            return
        }
        ClipboardWatcher.selfWrite { pasteboard in
            pasteboard.clearContents()
            pasteboard.writeObjects([url as NSURL])
        }
        ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
    }
}

private enum ImageConversionDropSupport {
    static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let string = item as? String { return URL(string: string) }
        return nil
    }
}
