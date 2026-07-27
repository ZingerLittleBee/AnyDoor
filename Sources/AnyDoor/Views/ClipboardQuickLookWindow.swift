import AppKit
import ImageIO
import PluginSupport
import QuickLookUI

/// Floating Quick Look preview for the wall's image / screenshot / file entries.
/// Mirrors `ClipboardTextWindow`'s preview mode: borderless, non-activating, and
/// never key — the wall keeps keyboard focus and drives it (Space/Esc close,
/// arrows follow the selection, Return still pastes).
///
/// Deliberately **not** the shared `QLPreviewPanel`. That panel takes key status
/// when shown, and the wall is a non-activating panel of a background
/// `.accessory` app: AnyDoor is never the *active* app, so the moment the shared
/// panel stole key from the wall, no keyboard event reached the process at all —
/// Space (and Esc) could no longer close the preview. Hosting `QLPreviewView` in
/// a panel that refuses key keeps every keystroke in the wall's key monitor.
@MainActor
final class ClipboardQuickLookWindow {
    static let shared = ClipboardQuickLookWindow()

    private var panel: NSPanel?
    private var previewView: QLPreviewView?
    private var mouseMonitors: [Any] = []
    /// The file currently previewed, so a repeated request for the same URL is
    /// a no-op instead of a flicker-inducing rebuild.
    private(set) var previewedURL: URL?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// Whether `window` is this preview panel (mouse routing in the wall).
    func owns(_ window: NSWindow?) -> Bool {
        window != nil && window === panel
    }

    /// Shows `url`, or swaps the content of an open preview (arrow-key follow).
    /// The panel is resized to the new item so a portrait shot doesn't sit in a
    /// landscape box.
    func show(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            close()
            return
        }
        if isVisible, previewedURL == url { return }
        if let panel, let previewView {
            previewedURL = url
            if let screen = panel.screen ?? NSScreen.main {
                panel.setFrame(Self.panelRect(for: url, on: screen), display: true, animate: false)
            }
            previewView.previewItem = url as NSURL
            return
        }
        present(url: url)
    }

    func close() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        // Releases the preview item and its (possibly out-of-process) renderer.
        previewView?.close()
        previewView = nil
        panel?.orderOut(nil)
        panel = nil
        previewedURL = nil
    }

    private func present(url: URL) {
        close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let rect = Self.panelRect(for: url, on: screen)

        let p = NonKeyPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isRestorable = false
        p.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]

        // Rounded, clipped container: an image fills it edge to edge, while a
        // document preview shows the window background behind its letterboxing.
        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.autoresizingMask = [.width, .height]

        let preview = QLPreviewView(frame: container.bounds, style: .normal) ?? QLPreviewView()
        preview.frame = container.bounds
        preview.autoresizingMask = [.width, .height]
        // Media must not start playing under a preview the user only glanced at.
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        preview.previewItem = url as NSURL
        container.addSubview(preview)

        p.contentView = container
        panel = p
        previewView = preview
        previewedURL = url

        // orderFrontRegardless: the app is not active (the wall is a
        // non-activating panel), and the preview must still show.
        p.orderFrontRegardless()
        installMouseMonitors()
    }

    /// Any mouse-down outside the panel closes it (clicks on the wall included,
    /// so picking a card by mouse drops the stale preview) — same rule as the
    /// floating text preview.
    private func installMouseMonitors() {
        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            MainThreadIsolation.run {
                if event.window !== self.panel { self.close() }
            }
            return event
        }
        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainThreadIsolation.run { self?.close() }
        }
        mouseMonitors = [local, global].compactMap { $0 }
    }

    /// Centered frame for `url`: an image is previewed at its natural point size
    /// (pixels ÷ the screen's backing scale, so a 2x screenshot shows at 1:1
    /// rather than double size), shrunk to fit the screen budget and never
    /// upscaled. Anything Quick Look renders as a document falls back to a
    /// generic box.
    private static func panelRect(for url: URL, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let budget = NSSize(width: visible.width * 0.6, height: visible.height * 0.7)
        guard let pixels = pixelSize(of: url) else {
            return centered(NSSize(width: visible.width * 0.6, height: visible.height * 0.6), in: visible)
        }
        let scale = max(screen.backingScaleFactor, 1)
        let natural = NSSize(width: pixels.width / scale, height: pixels.height / scale)
        let fit = min(1, min(budget.width / natural.width, budget.height / natural.height))
        let size = NSSize(
            width: max(240, (natural.width * fit).rounded()),
            height: max(160, (natural.height * fit).rounded())
        )
        return centered(size, in: visible)
    }

    private static func centered(_ size: NSSize, in frame: NSRect) -> NSRect {
        NSRect(
            x: (frame.midX - size.width / 2).rounded(),
            y: (frame.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
    }

    /// Pixel dimensions straight from the image header — no decode. Returns nil
    /// for anything that isn't an image ImageIO can read.
    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // Orientation 5...8 swap the axes; the preview honors them, so match.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}

/// Borderless panels already refuse key status, but `QLPreviewView` installs
/// focusable subviews — spell it out so nothing can hand the panel key and cut
/// the wall's keyboard off (the bug this whole window exists to avoid).
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
