import SwiftUI
import UniformTypeIdentifiers

/// A single clipboard entry rendered as a fixed-size card. Shows the source app
/// icon, kind label, relative time, and a kind-specific preview.
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
    var onRevealInFinder: (() -> Void)? = nil
    var onToggleTag: ((String) -> Void)? = nil
    var onNewTag: (() -> Void)? = nil
    var onIgnoreSource: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil
    /// When true the context menu returns empty, blocking right-clicks while a
    /// modal overlay (e.g. the tag dialog) is up above the card wall.
    var menuSuppressed: () -> Bool = { false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 230, height: 230)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            // strokeBorder draws inside the edge so the 2pt line stays within the
            // clipped bounds and its corners line up with the card's rounding.
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .opacity(item.isReferenceOnly && !ClipboardPasteService.canPaste(item, historyDirectory: historyDirectory) ? 0.5 : 1)
        // Native NSMenu instead of .contextMenu: SwiftUI's menu bridge
        // flash-resizes item icons on open (macOS 26); NSMenuItem.image renders
        // them Finder-style, stable. Left clicks pass through to the card.
        .overlay { RightClickMenu(makeMenu: makeContextMenu) }
    }

    /// Right-click menu, built at click time so favorite state and language
    /// are current. Edit only appears for text-bearing kinds.
    private func makeContextMenu() -> NSMenu {
        // Return empty when the wall has a modal overlay active (e.g. tag dialog).
        if menuSuppressed() { return NSMenu() }
        let menu = NSMenu()
        if item.historyKind?.isTextBearing == true, let onEdit {
            menu.addItem(ClosureMenuItem(
                title: L(.clipboardActionEdit), systemImage: "pencil", handler: onEdit
            ))
        }
        if let onCopy {
            menu.addItem(ClosureMenuItem(
                title: L(.clipboardActionCopy), systemImage: "doc.on.doc", handler: onCopy
            ))
        }
        if item.historyKind == .file, let onRevealInFinder {
            menu.addItem(ClosureMenuItem(
                title: L(.clipboardActionRevealInFinder), systemImage: "folder",
                handler: onRevealInFinder
            ))
        }
        if let onIgnoreSource, let bundleID = item.sourceBundleID {
            menu.addItem(ClosureMenuItem(
                title: L(.clipboardActionIgnoreSource, item.sourceAppName ?? bundleID),
                systemImage: "nosign",
                handler: onIgnoreSource
            ))
        }
        menu.addItem(ClosureMenuItem(
            title: L(item.isFavorite ? .clipboardActionUnfavorite : .clipboardActionFavorite),
            systemImage: item.isFavorite ? "star.slash" : "star",
            handler: onToggleFavorite
        ))
        if let submenu = makeTagSubmenu() { menu.addItem(submenu) }
        if let onDelete {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(
                title: L(.clipboardActionDelete), systemImage: "trash", handler: onDelete
            ))
        }
        return menu
    }

    /// "Add to Category ▸": checkable entries for every user-defined tag plus
    /// "New Category…". Built at click time so registry order, names, and the
    /// item's membership are current.
    private func makeTagSubmenu() -> NSMenuItem? {
        guard let onToggleTag, let onNewTag else { return nil }
        let parent = NSMenuItem(title: L(.clipboardActionAddToTag), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "tag", accessibilityDescription: nil)
        let submenu = NSMenu()
        for tag in ClipboardTagStore.shared.tags {
            let entry = ClosureMenuItem(title: tag.name) { onToggleTag(tag.id) }
            entry.state = item.tagIDs.contains(tag.id) ? .on : .off
            submenu.addItem(entry)
        }
        if !submenu.items.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(ClosureMenuItem(title: L(.clipboardTagNew), systemImage: "plus", handler: onNewTag))
        parent.submenu = submenu
        return parent
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
            // Passive favorite badge; toggling lives in the context menu.
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
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
           let icon = AppIconCache.iconForBundleSync(bundleID) {
            Image(nsImage: icon)
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
                    .font(.system(size: 13)).lineLimit(matchSnippet == nil ? 6 : 3)
                // Surface the matched line so a search hit buried below the first
                // line is visible rather than leaving the card looking unrelated.
                if let matchSnippet {
                    Text(matchSnippet)
                        .font(.system(size: 12)).lineLimit(2)
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
            if let fileName = item.fileName {
                ThumbnailView(url: historyDirectory.appendingPathComponent(fileName))
            } else {
                Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
            }
        case .file:
            // An image file gets a thumbnail like the image card; anything else
            // falls back to a document glyph plus its name.
            if let url = firstFileURL, isImageFile(url) {
                ThumbnailView(url: url)
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

    /// Image/file-card thumbnail decoded off the main thread via `ClipboardThumbnail`:
    /// reads the warm cache synchronously in `body`, and only kicks off the async
    /// decode on a miss, so many image cards sliding in no longer each run a
    /// full-resolution decode on the main thread. Unlike the lightweight source-app
    /// icon (resolved inline), the thumbnail decode is heavy enough to keep async.
    /// Shows a `photo` placeholder while the first decode is in flight.
    private struct ThumbnailView: View {
        let url: URL
        @State private var loaded: NSImage?

        var body: some View {
            Group {
                if let image = loaded ?? ClipboardThumbnail.cached(at: url) {
                    // Color.clear takes the offered preview frame; the image fills it
                    // as an overlay and is clipped to those bounds, so a large image
                    // can't overflow and cover the header.
                    Color.clear.overlay {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                    .clipped()
                } else {
                    Image(systemName: "photo").imageScale(.large).foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                if loaded == nil, ClipboardThumbnail.cached(at: url) == nil {
                    loaded = await ClipboardThumbnail.thumbnail(at: url)
                }
            }
        }
    }

}
