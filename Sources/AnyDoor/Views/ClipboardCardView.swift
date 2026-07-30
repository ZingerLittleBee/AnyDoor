import ClipboardHistory
import PluginInterface
import PluginSupport
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardCardView: View {
    let entry: ClipboardHistoryEntry
    let isSelected: Bool
    let presentation: ClipboardHistoryPresentationModel
    let onToggleFavorite: () -> Void
    var onEdit: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPluginAction:
        ((NativePluginID, PluginClipboardAction, PluginClipboardPayload) -> Void)?
    var onRevealInFinder: (() -> Void)?
    var onToggleTag: ((String) -> Void)?
    var onNewTag: (() -> Void)?
    var onIgnoreSource: (() -> Void)?
    var onDelete: (() -> Void)?
    var menuSuppressed: () -> Bool = { false }

    @State private var previewMaterialization:
        ClipboardHistoryMaterialization?
    @State private var hostMaterialization:
        ClipboardHistoryMaterialization?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 230, height: 230)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .overlay {
            RightClickMenu(makeMenu: makeContextMenu)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.presentationTitle)
        .task(id: entry.id) {
            async let preview = presentation.materialization(
                for: entry.id,
                purpose: .preview,
                recordsFailure: false
            )
            async let host = presentation.materialization(
                for: entry.id,
                purpose: .hostAction,
                recordsFailure: false
            )
            previewMaterialization = await preview
            hostMaterialization = await host
        }
    }

    private var pluginPayload: PluginClipboardPayload? {
        guard let hostMaterialization else { return nil }
        return ClipboardPluginPayloadMapper.payload(
            from: hostMaterialization,
            displayName: entry.presentationTitle
        )
    }

    private func makeContextMenu() -> NSMenu {
        if menuSuppressed() { return NSMenu() }
        let menu = NSMenu()
        if hostMaterialization?.editableText != nil, let onEdit {
            menu.addItem(
                ClosureMenuItem(
                    title: L(.clipboardActionEdit),
                    systemImage: "pencil",
                    handler: onEdit
                )
            )
        }
        if let onCopy {
            menu.addItem(
                ClosureMenuItem(
                    title: L(.clipboardActionCopy),
                    systemImage: "doc.on.doc",
                    handler: onCopy
                )
            )
        }
        if let onPluginAction, let pluginPayload {
            for (owner, action) in
                PluginRegistry.shared.clipboardActions(for: pluginPayload)
            {
                menu.addItem(
                    ClosureMenuItem(
                        title: L(raw: action.titleKey),
                        systemImage: action.symbol,
                        handler: {
                            onPluginAction(owner, action, pluginPayload)
                        }
                    )
                )
            }
        }
        if entry.facets.contains(.file), let onRevealInFinder {
            menu.addItem(
                ClosureMenuItem(
                    title: L(.clipboardActionRevealInFinder),
                    systemImage: "folder",
                    handler: onRevealInFinder
                )
            )
        }
        if let onIgnoreSource,
            let bundleID = entry.source.bundleIdentifier
        {
            menu.addItem(
                ClosureMenuItem(
                    title: L(
                        .clipboardActionIgnoreSource,
                        entry.source.displayName ?? bundleID
                    ),
                    systemImage: "nosign",
                    handler: onIgnoreSource
                )
            )
        }
        menu.addItem(
            ClosureMenuItem(
                title: L(
                    entry.isFavorite
                        ? .clipboardActionUnfavorite
                        : .clipboardActionFavorite
                ),
                systemImage: entry.isFavorite ? "star.slash" : "star",
                handler: onToggleFavorite
            )
        )
        if let submenu = makeTagSubmenu() {
            menu.addItem(submenu)
        }
        if let onDelete {
            menu.addItem(.separator())
            menu.addItem(
                ClosureMenuItem(
                    title: L(.clipboardActionDelete),
                    systemImage: "trash",
                    handler: onDelete
                )
            )
        }
        return menu
    }

    private func makeTagSubmenu() -> NSMenuItem? {
        guard let onToggleTag, let onNewTag else { return nil }
        let parent = NSMenuItem(
            title: L(.clipboardActionAddToTag),
            action: nil,
            keyEquivalent: ""
        )
        parent.image = NSImage(
            systemSymbolName: "tag",
            accessibilityDescription: nil
        )
        let submenu = NSMenu()
        for tag in ClipboardTagStore.shared.tags {
            let item = ClosureMenuItem(title: tag.name) {
                onToggleTag(tag.id)
            }
            item.state = entry.tagIDs.contains(tag.id) ? .on : .off
            submenu.addItem(item)
        }
        if !submenu.items.isEmpty {
            submenu.addItem(.separator())
        }
        submenu.addItem(
            ClosureMenuItem(
                title: L(.clipboardTagNew),
                systemImage: "plus",
                handler: onNewTag
            )
        )
        parent.submenu = submenu
        return parent
    }

    private var header: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                LocalizedText(entry.presentationTitleKey)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(entry.capturedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.yellow)
            }
            sourceIcon
                .frame(width: 22, height: 22)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let bundleID = entry.source.bundleIdentifier,
            let icon = AppIconCache.iconForBundleSync(bundleID)
        {
            Image(nsImage: icon)
                .resizable()
                .scaledToFit()
                .help(entry.source.displayName ?? "")
        }
    }

    @ViewBuilder
    private var preview: some View {
        switch entry.presentationFacet {
        case .text, .link, .email, .qrCode:
            Text(entry.previewText ?? "")
                .font(.system(size: 13))
                .lineLimit(6)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .padding(8)
        case .color:
            swatchColor
                .overlay(alignment: .bottomLeading) {
                    Text(entry.previewText ?? "")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(8)
                }
        case .image, .screenshot:
            if let data = previewMaterialization?.firstBitmapData,
                let image = NSImage(data: data)
            {
                imagePreview(image)
            } else {
                Image(systemName: "photo")
                    .imageScale(.large)
                    .foregroundStyle(.secondary)
            }
        case .file:
            if let url = hostMaterialization?.fileURLs.first,
                UTType(filenameExtension: url.pathExtension)?
                    .conforms(to: .image) == true
            {
                FileThumbnail(url: url)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "doc.fill").imageScale(.large)
                    Text(entry.presentationTitle)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .padding(8)
            }
        }
    }

    private var swatchColor: Color {
        if let color = previewMaterialization?.normalizedColor {
            return Color(nsColor: color)
        }
        return Color(hex: entry.previewText) ?? .black
    }

    private func imagePreview(_ image: NSImage) -> some View {
        Color.clear
            .overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            }
            .clipped()
    }

    private struct FileThumbnail: View {
        let url: URL
        @State private var image: NSImage?

        var body: some View {
            Group {
                if let image {
                    Color.clear
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFill()
                        }
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .imageScale(.large)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                image = await FileThumbnailCache.thumbnail(at: url)
            }
        }
    }
}
