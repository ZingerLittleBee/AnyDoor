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
    /// The menu panel this popover belongs to. A commit closes it, popover
    /// included, and then pastes into the app below it.
    let panel: ClipboardHistoryCommitSurface

    @State private var selection = ClipboardHistorySelectionModel()
    /// Whether Return copies without pasting. The hint follows Settings live.
    @AppStorage(ClipboardPreferences.copyOnlyKey) private var copyOnly = false

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
        // The menu bar reuses one hosting view and swaps its root for every
        // history row, so this view keeps its identity across mounts. Keying
        // the load to the model re-runs it for each freshly created one.
        .task(id: ObjectIdentifier(presentation)) {
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
                onCommit: { commit($0, plain: $1) },
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
                    hintChip(
                        "⏎",
                        labelKey: copyOnly ? .clipboardHintCopy : .clipboardHintPaste
                    )
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
                LocalizedText(.clipboardIndexing)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            LocalizedText(.clipboardEmpty)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .searchUnavailable:
            LocalizedText(.clipboardSearchUnavailable)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                            commit(entry, plain: false)
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

    /// A click, Return and keypad Enter commit here, ⌥ for plain text. The
    /// paste service closes the menu panel and pastes into the app below it,
    /// unless Copy only is on. A failure leaves the popover and the panel
    /// open behind its toast.
    private func commit(_ entry: ClipboardHistoryEntry, plain: Bool) {
        let presentation = presentation
        let panel = panel
        Task {
            await ClipboardHistoryPasteService.commit(
                entry.id,
                plain: plain,
                from: presentation,
                surface: panel,
                presentFailure: { ClipboardHistoryActionFailurePresenter.present($0) }
            )
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
            return Color(colorLiteral: entry.previewText) ?? .gray
        }
    }
}

/// What a key press means in a history popover. Kept apart from the view so
/// the mapping can be tested without a window.
enum ClipboardHistoryPopoverKey: Equatable {
    case moveUp
    case moveDown
    case togglePreview
    /// Return or keypad Enter; with ⌥ held, the entry pastes as plain text.
    case commit(plain: Bool)
    case escape

    init?(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        switch keyCode {
        case kVK_UpArrow:
            self = .moveUp
        case kVK_DownArrow:
            self = .moveDown
        case kVK_Space:
            self = .togglePreview
        case kVK_Return, kVK_ANSI_KeypadEnter:
            self = .commit(plain: modifierFlags.contains(.option))
        case kVK_Escape:
            self = .escape
        default:
            return nil
        }
    }
}

private struct KeyboardMonitor: NSViewRepresentable {
    let selection: ClipboardHistorySelectionModel
    let entries: [ClipboardHistoryEntry]
    let onCommit: (ClipboardHistoryEntry, _ plain: Bool) -> Void
    let onDismissPopover: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: selection,
            entries: entries,
            onCommit: onCommit,
            onDismissPopover: onDismissPopover
        )
    }

    func makeNSView(context: Context) -> KeyHandlerView {
        let view = KeyHandlerView()
        view.onKeyDown = { [weak coordinator = context.coordinator] code, flags in
            coordinator?.handle(keyCode: code, modifierFlags: flags) ?? false
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
        context.coordinator.onCommit = onCommit
        context.coordinator.onDismissPopover = onDismissPopover
        if let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    @MainActor
    final class Coordinator {
        let selection: ClipboardHistorySelectionModel
        var entries: [ClipboardHistoryEntry]
        /// Refreshed on every update. The menu bar remounts this view with a
        /// new presentation per history row while the coordinator lives on,
        /// so Return must not keep acting through the first mount's model.
        var onCommit: (ClipboardHistoryEntry, _ plain: Bool) -> Void
        var onDismissPopover: () -> Void

        init(
            selection: ClipboardHistorySelectionModel,
            entries: [ClipboardHistoryEntry],
            onCommit: @escaping (ClipboardHistoryEntry, _ plain: Bool) -> Void,
            onDismissPopover: @escaping () -> Void
        ) {
            self.selection = selection
            self.entries = entries
            self.onCommit = onCommit
            self.onDismissPopover = onDismissPopover
        }

        func handle(
            keyCode: Int,
            modifierFlags: NSEvent.ModifierFlags
        ) -> Bool {
            guard let key = ClipboardHistoryPopoverKey(
                keyCode: keyCode,
                modifierFlags: modifierFlags
            ) else {
                return false
            }
            switch key {
            case .moveUp:
                selection.moveUp()
            case .moveDown:
                selection.moveDown()
            case .togglePreview:
                selection.togglePreview()
            case .commit(let plain):
                guard let entry = selectedEntry else { return true }
                onCommit(entry, plain)
            case .escape:
                if selection.previewedID != nil {
                    selection.closePreview()
                } else {
                    onDismissPopover()
                }
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
    /// The key code and the modifiers held with it; ⌥ picks plain text.
    var onKeyDown: ((Int, NSEvent.ModifierFlags) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(Int(event.keyCode), event.modifierFlags) == true {
            return
        }
        super.keyDown(with: event)
    }
}
