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

    @Bindable var store: ClipboardHistoryStore
    let kind: ClipboardHistoryKind
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
                    .fill(Self.swatchColor(hex: item.colorHex) ?? Color.gray)
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

    /// Parse `"#RRGGBB"` (or `"RRGGBB"`) into a SwiftUI `Color`. Returns nil on
    /// malformed input so the preview can fall back to a neutral swatch.
    fileprivate static func swatchColor(hex: String?) -> Color? {
        guard var raw = hex?.uppercased() else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

// MARK: - Row

private struct ClipboardHistoryRow: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    let store: ClipboardHistoryStore

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(item.previewTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.previewSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(relativeTimestamp)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(rowBackground, in: .rect(cornerRadius: 6))
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.18) : .clear
    }

    @ViewBuilder
    private var leading: some View {
        switch item.historyKind {
        case .color:
            RoundedRectangle(cornerRadius: 4)
                .fill(ClipboardHistoryPopoverView.swatchColor(hex: item.colorHex) ?? Color.gray)
                .frame(width: 18, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        case .screenshot:
            if let url = store.screenshotURL(for: item),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "photo")
                    .frame(width: 24, height: 18)
                    .foregroundStyle(.secondary)
            }
        case .qrcode:
            Image(systemName: "qrcode")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        case .ocr, .none:
            Image(systemName: "text.viewfinder")
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
    }

    private var relativeTimestamp: String {
        Self.formatter.localizedString(for: item.createdAt, relativeTo: Date())
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
}

// MARK: - Keyboard monitor

/// Mirrors the pattern in `PortManagerPopoverView.KeyboardMonitor`: extracts
/// primitive key info from `NSEvent` (which is not `Sendable`) before
/// `MainActor.assumeIsolated` calls into the selection/store closures.
private struct KeyboardMonitor: NSViewRepresentable {
    @Bindable var selection: ClipboardHistorySelectionModel
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
