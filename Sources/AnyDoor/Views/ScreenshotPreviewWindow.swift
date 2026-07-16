import AppKit
import PluginInterface
import SwiftUI

/// Standalone borderless floating panel used for previewing a screenshot
/// history item at 60% of the active screen's visible frame, centered.
///
/// Uses `.nonactivatingPanel` so AnyDoor's `.accessory` activation policy and
/// the surrounding hover popover key state are left untouched. Closes on Esc
/// and on any mouse-down outside the panel frame, via local + global event
/// monitors.
@MainActor
final class ScreenshotPreviewWindow {
    static let shared = ScreenshotPreviewWindow()

    private var panel: NSPanel?
    @ObservationIgnored nonisolated(unsafe) private var localMouseMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var globalMouseMonitor: Any?
    @ObservationIgnored nonisolated(unsafe) private var keyMonitor: Any?

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

        let p = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        let hosting = NSHostingView(rootView: ScreenshotPreviewContent(image: image) { [weak self] in
            MainThreadIsolation.run { self?.close() }
        })
        hosting.frame = NSRect(origin: .zero, size: rect.size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p

        p.orderFrontRegardless()

        // Esc anywhere in this app closes the preview.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Esc */ else { return event }
            MainThreadIsolation.run { self?.close() }
            return nil
        }

        // Click anywhere inside this app outside the panel closes the preview
        // (events for our own app never reach the global monitor).
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            let inside = MainThreadIsolation.run { event.window === self.panel }
            if inside { return event }
            MainThreadIsolation.run { self.close() }
            return event
        }

        // Click in another app or on the desktop also closes.
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.close() }
        }
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m); localMouseMonitor = nil }
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m); globalMouseMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct ScreenshotPreviewContent: View {
    let image: NSImage
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.55))
                    .font(.system(size: 22, weight: .regular))
            }
            .buttonStyle(.plain)
            .help(L(.clipboardPreviewClose))
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .focusEffectDisabled()
    }
}
