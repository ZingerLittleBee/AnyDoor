import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Root SwiftUI view shown inside the Clipboard History `HoverPopover`.
///
/// Renders the newest-first cached items for a single `ClipboardHistoryKind`
/// plus an optional in-popover preview overlay. Drives hover/keyboard selection
/// via `ClipboardHistorySelectionModel`. Reads `store.cachedItems[kind]` so
/// `@Observable` tracking refreshes the body when new records arrive.
struct ClipboardHistoryPopoverView: View {
    private static let popoverWidth: CGFloat = 320
    private static let popoverHeight: CGFloat = 420

    let store: ClipboardHistoryStore
    let kind: ClipboardHistoryKind
    let onHoverChange: @MainActor (Bool) -> Void
    let onDismissPopover: () -> Void
    let onCopyAndClosePanel: () -> Void

    @State private var selection = ClipboardHistorySelectionModel()

    private var items: [ClipboardHistoryItem] {
        store.cachedItems[kind] ?? []
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }

            if let previewID = selection.previewedID,
               let previewItem = items.first(where: { $0.id == previewID }) {
                previewOverlay(for: previewItem)
            }
        }
        .frame(width: Self.popoverWidth, height: Self.popoverHeight)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHoverSafe(perform: onHoverChange)
        .onAppear {
            selection.replaceItems(items.map(\.id))
        }
        .onChange(of: items.map(\.id)) { _, newIDs in
            selection.replaceItems(newIDs)
        }
        .background(
            KeyboardMonitor(
                selection: selection,
                items: items,
                store: store,
                onCopyAndClosePanel: onCopyAndClosePanel,
                onDismissPopover: onDismissPopover
            )
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            LocalizedText(kind.titleKey).font(.headline)
            Text(L(.clipboardHeaderCountSuffix, items.count))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            if !items.isEmpty {
                keyboardHint
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var keyboardHint: some View {
        HStack(spacing: 6) {
            hintChip("↑↓", labelKey: .clipboardHintSelect)
            hintChip("Space", labelKey: .clipboardHintPreview)
            hintChip("⏎", labelKey: .clipboardHintCopy)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func hintChip(_ key: String, labelKey: L10n.Key) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            LocalizedText(labelKey)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                LocalizedText(.clipboardEmpty).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        ClipboardHistoryRow(
                            item: item,
                            isSelected: selection.selectedID == item.id,
                            store: store
                        )
                        .onHoverSafe { hovering in
                            if hovering { selection.select(item.id) }
                        }
                        .onTapGesture {
                            copyAndClose(item)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .overlayScrollers()
            }
        }
    }

    // MARK: Preview overlay

    @ViewBuilder
    private func previewOverlay(for item: ClipboardHistoryItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                LocalizedText(.clipboardPreviewTitle).font(.headline)
                Spacer()
                Button {
                    selection.closePreview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(L(.clipboardPreviewClose))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            previewBody(for: item)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(8)
        // Block click-through onto the underlying list, so taps on the
        // preview overlay don't accidentally re-copy a row beneath it.
        .contentShape(Rectangle())
        .onTapGesture { /* swallow */ }
    }

    @ViewBuilder
    private func previewBody(for item: ClipboardHistoryItem) -> some View {
        switch item.historyKind {
        case .ocr, .qrcode:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .overlayScrollers()
            }
        case .color:
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(ClipboardHistoryRow.swatchColor(forHex: item.colorHex) ?? Color.gray)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                    .frame(height: 140)
                Text(item.colorHex ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        case .screenshot:
            if let url = store.screenshotURL(for: item),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LocalizedText(.clipboardPreviewMissingFile).foregroundStyle(.secondary)
            }
        case .text, .image, .file, .none:
            // The per-kind hover popover intentionally renders only the four legacy
            // kinds (ocr/color/qrcode/screenshot). text/image/file are surfaced
            // exclusively in the clipboard wall, so they fall back here by design.
            LocalizedText(.clipboardPreviewCannotRender).foregroundStyle(.secondary)
        }
    }

    // MARK: Copy

    private func copyAndClose(_ item: ClipboardHistoryItem) {
        Task {
            do {
                try await store.copyToPasteboard(item)
                onCopyAndClosePanel()
            } catch {
                ToastPresenter.shared.show(.failure(L(.clipboardToastCopyFailed)))
            }
        }
    }
}

// MARK: - Keyboard monitor

/// Routes Up/Down/Space/Return/Esc into selection + copy logic.
///
/// Implementation note: previous version used `NSEvent.addLocalMonitorForEvents`,
/// but in the menu-bar + non-activating popover combo, arrow / Return keys
/// were intercepted by upstream handlers before reaching the local monitor
/// (Space happened to slip through, which made the bug confusing). Now we
/// install a first-responder NSView inside the popover panel that overrides
/// `keyDown(with:)` directly, which gets the events first via the panel's
/// own responder chain.
private struct KeyboardMonitor: NSViewRepresentable {
    let selection: ClipboardHistorySelectionModel
    let items: [ClipboardHistoryItem]
    let store: ClipboardHistoryStore
    let onCopyAndClosePanel: () -> Void
    let onDismissPopover: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selection: selection,
            items: items,
            store: store,
            onCopyAndClosePanel: onCopyAndClosePanel,
            onDismissPopover: onDismissPopover
        )
    }

    func makeNSView(context: Context) -> KeyHandlerView {
        let view = KeyHandlerView()
        view.onKeyDown = { [weak coordinator = context.coordinator] keyCode in
            guard let coordinator else { return false }
            return coordinator.handle(keyCode: keyCode)
        }
        // Defer first-responder grab until the view is in a window.
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: KeyHandlerView, context: Context) {
        context.coordinator.items = items
        context.coordinator.onCopyAndClosePanel = onCopyAndClosePanel
        context.coordinator.onDismissPopover = onDismissPopover
        // Re-assert first-responder in case the panel re-mounted us without
        // hooking up focus (e.g., updateContent swap inside HoverPopover).
        if let window = nsView.window, window.firstResponder !== nsView {
            window.makeFirstResponder(nsView)
        }
    }

    @MainActor
    final class Coordinator {
        let selection: ClipboardHistorySelectionModel
        var items: [ClipboardHistoryItem]
        let store: ClipboardHistoryStore
        var onCopyAndClosePanel: () -> Void
        var onDismissPopover: () -> Void

        init(
            selection: ClipboardHistorySelectionModel,
            items: [ClipboardHistoryItem],
            store: ClipboardHistoryStore,
            onCopyAndClosePanel: @escaping () -> Void,
            onDismissPopover: @escaping () -> Void
        ) {
            self.selection = selection
            self.items = items
            self.store = store
            self.onCopyAndClosePanel = onCopyAndClosePanel
            self.onDismissPopover = onDismissPopover
        }

        func handle(keyCode: Int) -> Bool {
            switch keyCode {
            case kVK_UpArrow:
                selection.moveUp()
                return true
            case kVK_DownArrow:
                selection.moveDown()
                return true
            case kVK_Space:
                // Screenshot items open a dedicated 60%-screen preview panel
                // and dismiss the popover; other kinds use the inline overlay.
                if let id = selection.selectedID,
                   let item = items.first(where: { $0.id == id }),
                   item.historyKind == .screenshot {
                    if let url = store.screenshotURL(for: item),
                       let image = NSImage(contentsOf: url) {
                        ScreenshotPreviewWindow.shared.show(image: image)
                    }
                    onDismissPopover()
                    return true
                }
                selection.togglePreview()
                return true
            case kVK_Return:
                guard let id = selection.selectedID,
                      let item = items.first(where: { $0.id == id }) else { return true }
                Task {
                    do {
                        try await self.store.copyToPasteboard(item)
                        self.onCopyAndClosePanel()
                    } catch {
                        ToastPresenter.shared.show(.failure(L(.clipboardToastCopyFailed)))
                    }
                }
                return true
            case kVK_Escape:
                if selection.previewedID != nil {
                    selection.closePreview()
                } else {
                    onDismissPopover()
                }
                return true
            default:
                return false
            }
        }
    }
}

/// First-responder NSView whose only job is to forward `keyDown` to a
/// SwiftUI-owned handler. Returning `false` calls `super.keyDown` so we
/// don't accidentally swallow keys we don't recognize (e.g., ⌘+letter).
final class KeyHandlerView: NSView {
    var onKeyDown: ((Int) -> Bool)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        if let handler = onKeyDown, handler(Int(event.keyCode)) {
            return
        }
        super.keyDown(with: event)
    }
}
