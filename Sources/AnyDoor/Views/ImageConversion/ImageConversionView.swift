import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImageConversionView: View {
    @Bindable var model: ImageConversionViewModel

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
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(item.folderPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
