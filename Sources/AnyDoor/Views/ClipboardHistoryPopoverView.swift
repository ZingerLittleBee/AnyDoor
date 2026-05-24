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
    let onHoverChange: (Bool) -> Void
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
        .onHover(perform: onHoverChange)
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
            Text(kind.title).font(.headline)
            Text("· \(items.count) 条")
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
            hintChip("↑↓", label: "选择")
            hintChip("Space", label: "预览")
            hintChip("⏎", label: "复制")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func hintChip(_ key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(label)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("暂无历史").foregroundStyle(.secondary)
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
                        .onHover { hovering in
                            if hovering { selection.select(item.id) }
                        }
                        .onTapGesture {
                            copyAndClose(item)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Preview overlay

    @ViewBuilder
    private func previewOverlay(for item: ClipboardHistoryItem) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("预览").font(.headline)
                Spacer()
                Button {
                    selection.closePreview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭预览")
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
                Text("截图不存在").foregroundStyle(.secondary)
            }
        case .none:
            Text("无法预览").foregroundStyle(.secondary)
        }
    }

    // MARK: Copy

    private func copyAndClose(_ item: ClipboardHistoryItem) {
        Task {
            do {
                try await store.copyToPasteboard(item)
                onCopyAndClosePanel()
            } catch {
                ToastPresenter.shared.show(.failure("复制失败"))
            }
        }
    }
}

// MARK: - Keyboard monitor

/// Mirrors the pattern in `PortManagerPopoverView.KeyboardMonitor`: extracts
/// primitive key info from `NSEvent` (which is not `Sendable`) before
/// `MainActor.assumeIsolated` calls into the selection/store closures.
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

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Keep the coordinator's references current so the key handler always
        // sees the latest items / closures without reinstalling the monitor.
        context.coordinator.items = items
        context.coordinator.onCopyAndClosePanel = onCopyAndClosePanel
        context.coordinator.onDismissPopover = onDismissPopover
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    @MainActor
    final class Coordinator {
        let selection: ClipboardHistorySelectionModel
        var items: [ClipboardHistoryItem]
        let store: ClipboardHistoryStore
        var onCopyAndClosePanel: () -> Void
        var onDismissPopover: () -> Void
        nonisolated(unsafe) private var monitor: Any?

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

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func install() {
            uninstall()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = Int(event.keyCode)
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(keyCode: keyCode)
                }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        private func handle(keyCode: Int) -> Bool {
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
                        ToastPresenter.shared.show(.failure("复制失败"))
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
