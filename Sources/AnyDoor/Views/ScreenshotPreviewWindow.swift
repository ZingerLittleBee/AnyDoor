import AppKit
import SwiftUI

/// Standalone borderless floating panel used for previewing a screenshot
/// history item at 60% of the active screen's visible frame, centered.
///
/// Becomes the key window so `cancelOperation` (Esc) reaches it. Closes when
/// the user clicks anywhere outside the panel, via `didResignKeyNotification`
/// — any other window taking key (the menu bar panel, another app, the
/// desktop) collapses the preview.
@MainActor
final class ScreenshotPreviewWindow {
    static let shared = ScreenshotPreviewWindow()

    private final class Panel: NSPanel {
        var onCancel: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
        override func cancelOperation(_ sender: Any?) { onCancel?() }
    }

    private var panel: Panel?
    @ObservationIgnored nonisolated(unsafe) private var resignObserver: NSObjectProtocol?

    private init() {}

    func show(image: NSImage, anchorScreen: NSScreen? = nil) {
        close()

        let screen = anchorScreen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let width = visible.width * 0.6
        let height = visible.height * 0.6
        let rect = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )

        let p = Panel(
            contentRect: rect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        p.onCancel = { [weak self] in self?.close() }

        let hosting = NSHostingView(rootView: ScreenshotPreviewContent(image: image))
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: p,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }

        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScreenshotPreviewContent: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
