import SwiftUI

/// A single clipboard entry rendered as a fixed-size card. Shows the source app
/// icon, kind label, relative time, a kind-specific preview, and a favorite star.
struct ClipboardCardView: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let historyDirectory: URL
    let onToggleFavorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 150, height: 150)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(item.isReferenceOnly && !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) ? 0.5 : 1)
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                kindLabel
                    .font(.caption2).foregroundStyle(.secondary)
                Text(item.createdAt, style: .relative)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            // Prominent source-app logo (Paste-style), top-right of the card.
            sourceIcon.frame(width: 22, height: 22)
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
    }

    /// Localized kind label that reacts to live language switches. Renders empty
    /// when the persisted kind raw value no longer maps to a known case.
    @ViewBuilder
    private var kindLabel: some View {
        if let key = item.historyKind?.titleKey {
            LocalizedText(key)
        } else {
            Text("")
        }
    }

    /// The source app's icon, resolved from the captured bundle identifier. Hidden
    /// for entries with no recorded source (e.g. legacy OCR/screenshot items) so
    /// the header stays clean rather than showing a generic placeholder.
    @ViewBuilder
    private var sourceIcon: some View {
        if let bundleID = item.sourceBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().scaledToFit()
                .help(item.sourceAppName ?? "")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch item.historyKind {
        case .text, .ocr, .qrcode:
            Text(item.text ?? item.previewTitle)
                .font(.system(size: 11)).lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
        case .color:
            Rectangle().fill(Color(hex: item.colorHex) ?? .black)
                .overlay(alignment: .bottomLeading) {
                    Text(item.colorHex ?? "").font(.caption2).foregroundStyle(.white).padding(8)
                }
        case .image, .screenshot:
            if let fileName = item.fileName,
               let img = NSImage(contentsOf: historyDirectory.appendingPathComponent(fileName)) {
                Image(nsImage: img).resizable().scaledToFill().clipped()
            } else {
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
        case .file:
            VStack(spacing: 6) {
                Image(systemName: "doc.fill").imageScale(.large)
                Text(item.previewTitle).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
            }.padding(8)
        case .none:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(item.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}
