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
    private var containerView: NSView?
    private var previewView: QLPreviewView?
    private var mouseMonitors: [Any] = []
    /// The file currently previewed, so a repeated request for the same URL is
    /// a no-op instead of a flicker-inducing rebuild.
    private var previewedURL: URL?
    private var previewedBitmap: Data?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    /// Shows `url`, or swaps the content of an open preview (arrow-key follow).
    /// The panel is resized to the new item so a portrait shot doesn't sit in a
    /// landscape box.
    func show(url: URL) {
        if isVisible, previewedURL == url { return }
        if let panel, let containerView {
            previewedURL = url
            previewedBitmap = nil
            if let screen = panel.screen ?? NSScreen.main {
                panel.setFrame(Self.panelRect(for: url, on: screen), display: true, animate: false)
            }
            replaceContent(with: url, in: containerView)
            return
        }
        present(url: url)
    }

    func show(bitmapData: Data) {
        if isVisible, previewedBitmap == bitmapData { return }
        if let panel, let containerView {
            previewedURL = nil
            previewedBitmap = bitmapData
            if let screen = panel.screen ?? NSScreen.main {
                panel.setFrame(
                    Self.panelRect(for: bitmapData, on: screen),
                    display: true,
                    animate: false
                )
            }
            replaceContent(with: bitmapData, in: containerView)
            return
        }
        present(bitmapData: bitmapData)
    }

    func close() {
        for monitor in mouseMonitors { NSEvent.removeMonitor(monitor) }
        mouseMonitors = []
        // Releases the preview item and its (possibly out-of-process) renderer.
        previewView?.close()
        previewView = nil
        containerView = nil
        panel?.orderOut(nil)
        panel = nil
        previewedURL = nil
        previewedBitmap = nil
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

        p.contentView = container
        panel = p
        containerView = container
        previewedURL = url
        previewedBitmap = nil
        replaceContent(with: url, in: container)

        // orderFrontRegardless: the app is not active (the wall is a
        // non-activating panel), and the preview must still show.
        p.orderFrontRegardless()
        installMouseMonitors()
    }

    private func present(bitmapData: Data) {
        close()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let rect = Self.panelRect(for: bitmapData, on: screen)
        let panel = makePanel(rect: rect)
        let container = makeContainer(rect: rect)
        panel.contentView = container
        self.panel = panel
        containerView = container
        previewedURL = nil
        previewedBitmap = bitmapData
        replaceContent(with: bitmapData, in: container)
        panel.orderFrontRegardless()
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

    /// Replaces the rendered item without rebuilding the panel. Missing files
    /// stay visible as an inline failure state so Space never appears to do
    /// nothing and arrow navigation can continue to the next card.
    private func replaceContent(with url: URL, in container: NSView) {
        previewView?.close()
        previewView = nil
        container.subviews.forEach { $0.removeFromSuperview() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            container.addSubview(Self.missingFileView(frame: container.bounds))
            return
        }

        let preview = QLPreviewView(frame: container.bounds, style: .normal) ?? QLPreviewView()
        preview.frame = container.bounds
        preview.autoresizingMask = [.width, .height]
        // Media must not start playing under a preview the user only glanced at.
        preview.autostarts = false
        preview.shouldCloseWithWindow = false
        preview.previewItem = url as NSURL
        container.addSubview(preview)
        previewView = preview
    }

    private func replaceContent(with data: Data, in container: NSView) {
        previewView?.close()
        previewView = nil
        container.subviews.forEach { $0.removeFromSuperview() }
        guard let image = NSImage(data: data) else {
            container.addSubview(Self.missingFileView(frame: container.bounds))
            return
        }
        let imageView = NSImageView(frame: container.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        container.addSubview(imageView)
    }

    private static func missingFileView(frame: NSRect) -> NSView {
        let image = NSImageView()
        image.image = NSImage(
            systemSymbolName: "exclamationmark.triangle",
            accessibilityDescription: L(.clipboardPreviewMissingFile)
        )
        image.contentTintColor = .secondaryLabelColor
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        let label = NSTextField(wrappingLabelWithString: L(.clipboardPreviewMissingFile))
        label.alignment = .center
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [image, label])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView(frame: frame)
        view.autoresizingMask = [.width, .height]
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        return view
    }

    /// Centered frame for `url`: an image is previewed at its natural point size
    /// (pixels ÷ the screen's backing scale, so a 2x screenshot shows at 1:1
    /// rather than double size), uniformly scaled to fit the screen budget while
    /// preserving its aspect ratio. Anything Quick Look renders as a document
    /// falls back to a generic box.
    private static func panelRect(for url: URL, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: pixelSize(of: url),
            backingScale: screen.backingScaleFactor,
            visibleSize: visible.size
        )
        return centered(size, in: visible)
    }

    private static func panelRect(
        for data: Data,
        on screen: NSScreen
    ) -> NSRect {
        let visible = screen.visibleFrame
        let size = ClipboardQuickLookGeometry.panelSize(
            pixelSize: pixelSize(of: data),
            backingScale: screen.backingScaleFactor,
            visibleSize: visible.size
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

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
            ) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            width > 0,
            height > 0
        else {
            return nil
        }
        let orientation =
            properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    private func makePanel(rect: NSRect) -> NSPanel {
        let panel = NonKeyPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .moveToActiveSpace,
        ]
        return panel
    }

    private func makeContainer(rect: NSRect) -> NSView {
        let container = NSView(
            frame: NSRect(origin: .zero, size: rect.size)
        )
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor =
            NSColor.windowBackgroundColor.cgColor
        container.autoresizingMask = [.width, .height]
        return container
    }
}

enum ClipboardQuickLookGeometry {
    private static let minimumSize = CGSize(width: 240, height: 160)

    /// Returns an aspect-preserving panel size. Small images are uniformly
    /// enlarged enough to meet the preferred minimum when the screen permits;
    /// large or extreme-aspect images always prioritize fitting the screen.
    static func panelSize(
        pixelSize: CGSize?,
        backingScale: CGFloat,
        visibleSize: CGSize
    ) -> CGSize {
        let budget = CGSize(width: visibleSize.width * 0.6, height: visibleSize.height * 0.7)
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return CGSize(width: visibleSize.width * 0.6, height: visibleSize.height * 0.6)
        }

        let scale = max(backingScale, 1)
        let natural = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        let fitScale = min(budget.width / natural.width, budget.height / natural.height)
        let minimumScale = max(
            minimumSize.width / natural.width,
            minimumSize.height / natural.height
        )
        let appliedScale = min(fitScale, max(1, minimumScale))
        return CGSize(
            width: (natural.width * appliedScale).rounded(),
            height: (natural.height * appliedScale).rounded()
        )
    }
}

/// Borderless panels already refuse key status, but `QLPreviewView` installs
/// focusable subviews — spell it out so nothing can hand the panel key and cut
/// the wall's keyboard off (the bug this whole window exists to avoid).
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
