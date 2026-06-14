import AppKit
import SwiftUI

/// Actions the overlay can request. The coordinator supplies the implementations.
@MainActor
struct CaptureOverlayActions {
    var copy: () -> Void
    var save: () -> Void
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

    private static let overlaySize = CGSize(width: 280, height: 96)

    func present(image: NSImage, fileURL: URL?, anchor: CGRect?, timeout: Int, actions: CaptureOverlayActions) {
        close()
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame: CGRect
        if let anchor {
            frame = OverlayPlacement.frame(forRegion: anchor, overlaySize: Self.overlaySize, onScreen: screen.frame, gap: 12)
        } else {
            frame = OverlayPlacement.fallbackFrame(overlaySize: Self.overlaySize, onScreen: screen.frame, margin: 16)
        }

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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]

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
    let onHoverChange: (Bool) -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    button("doc.on.doc", L(.captureOverlayCopy), actions.copy)
                    button("square.and.arrow.down", L(.captureOverlaySave), actions.save)
                    button("pencil.tip.crop.circle", L(.captureOverlayEdit), actions.edit)
                    button("pin", L(.captureOverlayPin), actions.pin)
                }
                HStack(spacing: 10) {
                    button("text.viewfinder", L(.captureOverlayOCR), actions.ocr)
                    button("arrow.clockwise", L(.captureOverlayRecapture), actions.recapture)
                    button("trash", L(.captureOverlayDelete), actions.delete)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, height: 96)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { onHoverChange($0) }
    }

    private var thumbnail: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onDrag { dragProvider() }
    }

    private func dragProvider() -> NSItemProvider {
        if let fileURL { return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image) }
        return NSItemProvider(object: image)
    }

    private func button(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button {
            run()
            onAction()
        } label: {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
