import AppKit
import Carbon.HIToolbox
import ClipboardHistory
import PluginSupport
import SwiftUI

struct ClipboardHistoryPopoverView: View {
    private static let popoverWidth: CGFloat = 320
    private static let popoverHeight: CGFloat = 420

    @Bindable var presentation: ClipboardHistoryPresentationModel
    let facet: ClipboardHistoryFacet
    let titleKey: L10n.Key
    let onHoverChange: @MainActor (Bool) -> Void
    let onDismissPopover: () -> Void
    let onCopyAndClosePanel: () -> Void

    @State private var selection = ClipboardHistorySelectionModel()

    private var entries: [ClipboardHistoryEntry] {
        presentation.entries
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            if let previewID = selection.previewedID,
                let entry = entries.first(where: { $0.id == previewID })
            {
                PreviewOverlay(
                    entry: entry,
                    presentation: presentation,
                    onClose: selection.closePreview
                )
            }
        }
        .frame(
            width: Self.popoverWidth,
            height: Self.popoverHeight
        )
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHoverSafe(perform: onHoverChange)
        .task {
            await presentation.setQuery(
                ClipboardHistoryQuery(facet: facet)
            )
            selection.replaceItems(entries.map(\.id))
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            selection.replaceItems(ids)
        }
        .background(
            KeyboardMonitor(
                selection: selection,
                entries: entries,
                presentation: presentation,
                onCopyAndClosePanel: onCopyAndClosePanel,
                onDismissPopover: onDismissPopover
            )
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            LocalizedText(titleKey).font(.headline)
            Text(L(.clipboardHeaderCountSuffix, entries.count))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if !entries.isEmpty {
                HStack(spacing: 6) {
                    hintChip("↑↓", labelKey: .clipboardHintSelect)
                    hintChip("Space", labelKey: .clipboardHintPreview)
                    hintChip("⏎", labelKey: .clipboardHintCopy)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func hintChip(
        _ key: String,
        labelKey: L10n.Key
    ) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                )
            LocalizedText(labelKey)
        }
        .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch presentation.contentState {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .indexing:
            VStack(spacing: 8) {
                ProgressView()
                LocalizedText(.clipboardEmpty)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            LocalizedText(.clipboardEmpty)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable:
            LocalizedText(.clipboardPreviewCannotRender)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(entries, id: \.id) { entry in
                        ClipboardHistoryRow(
                            entry: entry,
                            isSelected: selection.selectedID == entry.id,
                            presentation: presentation
                        )
                        .onHoverSafe { hovering in
                            if hovering {
                                selection.select(entry.id)
                            }
                        }
                        .onTapGesture {
                            copyAndClose(entry)
                        }
                        .task {
                            await presentation.prefetchIfNeeded(
                                visibleID: entry.id
                            )
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .overlayScrollers()
            }
        }
    }

    private func copyAndClose(_ entry: ClipboardHistoryEntry) {
        Task {
            guard let materialization = await presentation.materialization(
                for: entry.id,
                purpose: .normalPaste,
                usesCache: false
            ) else {
                ClipboardHistoryActionFailurePresenter.present(
                    presentation.actionFailure
                )
                return
            }
            do {
                try ClipboardSelfWrites.perform { pasteboard in
                    try ClipboardHistoryPasteService.write(
                        materialization,
                        to: pasteboard
                    )
                }
                onCopyAndClosePanel()
            } catch {
                ClipboardHistoryActionFailurePresenter.present(.unknown)
            }
        }
    }

    private struct PreviewOverlay: View {
        let entry: ClipboardHistoryEntry
        let presentation: ClipboardHistoryPresentationModel
        let onClose: () -> Void

        @State private var materialization:
            ClipboardHistoryMaterialization?

        var body: some View {
            VStack(spacing: 0) {
                HStack {
                    LocalizedText(.clipboardPreviewTitle).font(.headline)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L(.clipboardPreviewClose))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Divider()
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(12)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(8)
            .contentShape(Rectangle())
            .onTapGesture {}
            .task(id: entry.id) {
                materialization = await presentation.materialization(
                    for: entry.id,
                    purpose: .preview,
                    recordsFailure: false
                )
            }
        }

        @ViewBuilder
        private var preview: some View {
            if let data = materialization?.firstBitmapData,
                let image = NSImage(data: data)
            {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if entry.presentationFacet == .color {
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(swatchColor)
                        .frame(height: 140)
                    Text(entry.previewText ?? "—")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else if let text = entry.previewText {
                ScrollView {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .overlayScrollers()
                }
            } else {
                LocalizedText(.clipboardPreviewCannotRender)
                    .foregroundStyle(.secondary)
            }
        }

        private var swatchColor: Color {
            if let color = materialization?.normalizedColor {
                return Color(nsColor: color)
            }
            return Color(hex: entry.previewText) ?? .gray
        }
    }
}

private struct KeyboardMonitor: NSViewRepresentable {
    let selection: ClipboardHistorySelectionModel
    let entries: [ClipboardHistoryEntry]
    let presentation: ClipboardHistoryPresentationModel
    let onCopyAndClosePanel: () -> Void
    let onDismissPopover: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: selection,
            entries: entries,
            presentation: presentation,
            onCopyAndClosePanel: onCopyAndClosePanel,
            onDismissPopover: onDismissPopover
        )
    }

    func makeNSView(context: Context) -> KeyHandlerView {
        let view = KeyHandlerView()
        view.onKeyDown = { [weak coordinator = context.coordinator] code in
            coordinator?.handle(keyCode: code) ?? false
        }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(
        _ nsView: KeyHandlerView,
        context: Context
    ) {
        context.coordinator.entries = entries
        context.coordinator.onCopyAndClosePanel = onCopyAndClosePanel
        context.coordinator.onDismissPopover = onDismissPopover
        if let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    @MainActor
    final class Coordinator {
        let selection: ClipboardHistorySelectionModel
        var entries: [ClipboardHistoryEntry]
        let presentation: ClipboardHistoryPresentationModel
        var onCopyAndClosePanel: () -> Void
        var onDismissPopover: () -> Void

        init(
            selection: ClipboardHistorySelectionModel,
            entries: [ClipboardHistoryEntry],
            presentation: ClipboardHistoryPresentationModel,
            onCopyAndClosePanel: @escaping () -> Void,
            onDismissPopover: @escaping () -> Void
        ) {
            self.selection = selection
            self.entries = entries
            self.presentation = presentation
            self.onCopyAndClosePanel = onCopyAndClosePanel
            self.onDismissPopover = onDismissPopover
        }

        func handle(keyCode: Int) -> Bool {
            switch keyCode {
            case kVK_UpArrow:
                selection.moveUp()
            case kVK_DownArrow:
                selection.moveDown()
            case kVK_Space:
                selection.togglePreview()
            case kVK_Return:
                guard let entry = selectedEntry else { return true }
                Task {
                    guard let value = await presentation.materialization(
                        for: entry.id,
                        purpose: .normalPaste,
                        usesCache: false
                    ) else {
                        ClipboardHistoryActionFailurePresenter.present(
                            presentation.actionFailure
                        )
                        return
                    }
                    do {
                        try ClipboardSelfWrites.perform { pasteboard in
                            try ClipboardHistoryPasteService.write(
                                value,
                                to: pasteboard
                            )
                        }
                        onCopyAndClosePanel()
                    } catch {
                        ClipboardHistoryActionFailurePresenter.present(
                            .unknown
                        )
                    }
                }
            case kVK_Escape:
                if selection.previewedID != nil {
                    selection.closePreview()
                } else {
                    onDismissPopover()
                }
            default:
                return false
            }
            return true
        }

        private var selectedEntry: ClipboardHistoryEntry? {
            guard let id = selection.selectedID else { return nil }
            return entries.first { $0.id == id }
        }
    }
}

final class KeyHandlerView: NSView {
    var onKeyDown: ((Int) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(Int(event.keyCode)) == true {
            return
        }
        super.keyDown(with: event)
    }
}
