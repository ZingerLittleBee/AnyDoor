import AppKit
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
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted, perform: handleDrop)
        .focusEffectDisabled()
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Label {
                LocalizedText(.imageConversionTitle)
                    .font(.headline)
            } icon: {
                Image(systemName: "photo.on.rectangle")
            }
            Spacer()
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
                .frame(width: 112)
            }
            if model.isQualityAdjustable {
                qualityControl
            }
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

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 30, height: 30)
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
    }

    private var iconImage: NSImage {
        if let url = item.fileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if case let .bitmap(data) = item.payload, let image = NSImage(data: data) {
            return image
        }
        return NSWorkspace.shared.icon(for: .image)
    }
}

private struct ImageConversionHistoryRow: View {
    let record: ImageConversionRecord

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: previewImage)
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
    }

    /// Resolves the preview from the output path at render time; a deleted file
    /// degrades to a generic placeholder rather than a broken image.
    private var previewImage: NSImage {
        if FileManager.default.fileExists(atPath: record.outputPath),
           let image = NSImage(contentsOfFile: record.outputPath) {
            return image
        }
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
