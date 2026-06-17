import AppKit
import SwiftUI

/// Actions the overlay can request. The coordinator supplies the implementations.
@MainActor
struct CaptureOverlayActions {
    var copy: () -> Void
    /// "Save As": always opens a save panel to pick a destination.
    var save: () -> Void
    /// Reveal the auto-saved file in Finder. `nil` unless auto-save wrote a file.
    var reveal: (() -> Void)?
    var edit: () -> Void
    var pin: () -> Void
    var ocr: () -> Void
    var recapture: () -> Void
    var delete: () -> Void
}

/// Non-activating panel that shows the capture thumbnail (a drag source) plus an
/// action row. Positioned by `OverlayPlacement`. Auto-dismisses after a timeout
/// unless the pointer is inside it.
@MainActor
final class CaptureOverlayWindow {
    static let shared = CaptureOverlayWindow()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private static let overlaySize = CGSize(width: 394, height: 136)

    private init() {}

    func present(image: NSImage, fileURL: URL?, timeout: Int, actions: CaptureOverlayActions) {
        close()
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        // The quick-access overlay always docks at the bottom-left of the screen
        // under the cursor, regardless of where the capture was taken. The visible
        // frame keeps it clear of the Dock and menu bar.
        let frame = OverlayPlacement.bottomLeftFrame(
            overlaySize: Self.overlaySize, onScreen: screen.visibleFrame, margin: 16
        )

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive
        // (both set the space-membership policy); combining them makes macOS 26's
        // `_validateCollectionBehavior` throw an NSException. Keep one space option.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: CaptureOverlayView(
            image: image,
            fileURL: fileURL,
            actions: actions,
            onHoverChange: { [weak self] hovering in
                if hovering { self?.cancelDismiss() } else { self?.scheduleDismiss(after: timeout) }
            },
            onAction: { [weak self] in self?.close() }
        ))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()
        scheduleDismiss(after: timeout)
    }

    private func scheduleDismiss(after seconds: Int) {
        cancelDismiss()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func close() {
        cancelDismiss()
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - SwiftUI overlay view

private struct CaptureOverlayView: View {
    let image: NSImage
    let fileURL: URL?
    let actions: CaptureOverlayActions
    let onHoverChange: @MainActor (Bool) -> Void
    let onAction: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(54), spacing: 6), count: 4)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            thumbnail
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(actionItems, id: \.symbol) { item in
                    OverlayActionTile(symbol: item.symbol, label: item.label, role: item.role) {
                        item.run()
                        onAction()
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 394, height: 136)
        .adaptivePanelSurface(cornerRadius: 18)
        .onHoverSafe { onHoverChange($0) }
    }

    // MARK: Thumbnail (drag source)

    private var thumbnail: some View {
        VStack(spacing: 5) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 112, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
                )
                .onDrag { dragProvider() }
            Label(L(.captureOverlayDragHint), systemImage: "hand.draw")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(width: 112)
    }

    private func dragProvider() -> NSItemProvider {
        if let fileURL { return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image) }
        return NSItemProvider(object: image)
    }

    // MARK: Action model

    private struct ActionItem {
        let symbol: String
        let label: String
        let role: OverlayActionTile.Role
        let run: () -> Void
    }

    private var actionItems: [ActionItem] {
        var items = [
            ActionItem(symbol: "doc.on.doc", label: L(.captureOverlayCopy), role: .standard, run: actions.copy),
            ActionItem(symbol: "square.and.arrow.down", label: L(.captureOverlaySaveAs), role: .standard, run: actions.save),
        ]
        // Only when auto-save wrote a file: reveal it in Finder.
        if let reveal = actions.reveal {
            items.append(ActionItem(symbol: "folder", label: L(.captureOverlayReveal), role: .standard, run: reveal))
        }
        items += [
            ActionItem(symbol: "pencil.tip.crop.circle", label: L(.captureOverlayEdit), role: .standard, run: actions.edit),
            ActionItem(symbol: "pin", label: L(.captureOverlayPin), role: .standard, run: actions.pin),
            ActionItem(symbol: "text.viewfinder", label: L(.captureOverlayOCR), role: .standard, run: actions.ocr),
            ActionItem(symbol: "arrow.clockwise", label: L(.captureOverlayRecapture), role: .standard, run: actions.recapture),
            ActionItem(symbol: "trash", label: L(.captureOverlayDelete), role: .destructive, run: actions.delete),
        ]
        return items
    }
}

/// A single icon-above-label action tile with a hover highlight. Mirrors the
/// capture selection toolbar's button language so the capture surfaces stay
/// consistent, and surfaces a label under every icon so each action is legible
/// at a glance.
private struct OverlayActionTile: View {
    enum Role { case standard, destructive }

    let symbol: String
    let label: String
    let role: Role
    let run: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(height: 20)
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(width: 54, height: 44)
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHoverSafe { isHovered = $0 }
    }
}
