import SwiftUI
import UniformTypeIdentifiers

/// A single clipboard entry rendered as a fixed-size card. Shows the source app
/// icon, kind label, relative time, a kind-specific preview, and a favorite star.
struct ClipboardCardView: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let historyDirectory: URL
    /// The text line that matched the active search, when the match falls below
    /// the visible first line. Shown so a search hit is visible on the card.
    var matchSnippet: String? = nil
    let onToggleFavorite: () -> Void
    /// Context-menu actions; nil hides the matching menu item (previews/tests).
    var onEdit: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .frame(width: 190, height: 190)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            // strokeBorder draws inside the edge so the 2pt line stays within the
            // clipped bounds and its corners line up with the card's rounding.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(item.isReferenceOnly && !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) ? 0.5 : 1)
        .contextMenu { contextMenuItems }
    }

    /// Right-click menu. Edit only appears for text-bearing kinds; Favorite
    /// flips its label with the current state.
    @ViewBuilder
    private var contextMenuItems: some View {
        if item.historyKind?.isTextBearing == true, let onEdit {
            Button(action: onEdit) {
                Label { LocalizedText(.clipboardActionEdit) } icon: { Image(systemName: "pencil") }
            }
        }
        if let onCopy {
            Button(action: onCopy) {
                Label { LocalizedText(.clipboardActionCopy) } icon: { Image(systemName: "doc.on.doc") }
            }
        }
        Button(action: onToggleFavorite) {
            Label {
                LocalizedText(item.isFavorite ? .clipboardActionUnfavorite : .clipboardActionFavorite)
            } icon: {
                Image(systemName: item.isFavorite ? "star.slash" : "star")
            }
        }
        if let onDelete {
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label { LocalizedText(.clipboardActionDelete) } icon: { Image(systemName: "trash") }
            }
        }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text ?? item.previewTitle)
                    .font(.system(size: 11)).lineLimit(matchSnippet == nil ? 6 : 3)
                // Surface the matched line so a search hit buried below the first
                // line is visible rather than leaving the card looking unrelated.
                if let matchSnippet {
                    Text(matchSnippet)
                        .font(.system(size: 10)).lineLimit(2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(8)
        case .color:
            (Color(hex: item.colorHex) ?? .black)
                .overlay(alignment: .bottomLeading) {
                    Text((item.colorHex ?? "").uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(8)
                }
        case .image, .screenshot:
            if let fileName = item.fileName,
               let img = ClipboardThumbnail.image(at: historyDirectory.appendingPathComponent(fileName)) {
                // Color.clear takes the offered preview frame; the image fills it
                // as an overlay and is clipped to those bounds, so a large image
                // can't overflow and cover the header/footer.
                Color.clear.overlay {
                    Image(nsImage: img).resizable().scaledToFill()
                }
                .clipped()
            } else {
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
        case .file:
            // An image file gets a thumbnail like the image card; anything else
            // falls back to a document glyph plus its name.
            if let url = firstFileURL, isImageFile(url), let img = ClipboardThumbnail.image(at: url) {
                Color.clear.overlay {
                    Image(nsImage: img).resizable().scaledToFill()
                }
                .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill").imageScale(.large)
                    Text(item.previewTitle).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                }.padding(8)
            }
        case .none:
            EmptyView()
        }
    }

    /// Resolved URL of the entry's first file: the copy stored in the history
    /// directory when present, otherwise the original on-disk path.
    private var firstFileURL: URL? {
        guard let first = item.files.first else { return nil }
        if let stored = first.storedName {
            return historyDirectory.appendingPathComponent(stored)
        }
        return URL(fileURLWithPath: first.originalPath)
    }

    private func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
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
