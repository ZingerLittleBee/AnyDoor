import AppKit
import CoreGraphics

/// Presents a full-screen, non-activating selection overlay over the display under
/// the mouse. On show it captures a single frozen still of that display (freeze
/// screen) and lets the user pick either a region (drag a rectangle, cropped from
/// the frozen still) or a window (highlight + click). Calls `completion` exactly
/// once with a `SelectionResult`, then tears the panel down.
@MainActor
final class SelectionOverlayWindow {
    private var panel: NSPanel?
    private var completion: ((SelectionResult) -> Void)?

    func present(mode: CaptureMode, completion: @escaping (SelectionResult) -> Void) async {
        self.completion = completion
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let displayID = screen.displayID else { finish(.cancelled); return }
        let frozen: CGImage
        do { frozen = try await ScreenCaptureService.shared.captureDisplay(displayID) }
        catch { finish(.cancelled); return }

        let p = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionOverlayView(
            mode: mode,
            screenFrame: screen.frame,
            backingScale: screen.backingScaleFactor,
            frozen: frozen
        )
        view.onRegion = { [weak self] image, rect in self?.finish(.region(image: image, rect: rect)) }
        view.onWindow = { [weak self] id, frame in self?.finish(.window(id: id, frame: frame)) }
        view.onCancel = { [weak self] in self?.finish(.cancelled) }
        p.contentView = view
        panel = p
        p.orderFrontRegardless()
        p.makeFirstResponder(view)
    }

    private func finish(_ result: SelectionResult) {
        panel?.orderOut(nil)
        panel = nil
        let c = completion
        completion = nil
        c?(result)
    }
}

private final class SelectionOverlayView: NSView {
    var onRegion: ((CGImage, CGRect) -> Void)?
    var onWindow: ((CGWindowID, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let mode: CaptureMode
    private let screenFrame: CGRect
    private let backingScale: CGFloat
    private let frozen: CGImage
    private let windows: [CapturableWindow]

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    private var hoveredWindow: CapturableWindow?

    init(mode: CaptureMode, screenFrame: CGRect, backingScale: CGFloat, frozen: CGImage) {
        self.mode = mode
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        self.frozen = frozen
        self.windows = mode == .window ? WindowEnumerator.onScreenWindows() : []
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        NSCursor.crosshair.set()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Coordinate conversions

    /// Local view point (bottom-left origin, relative to this screen's content view)
    /// -> global AppKit screen point (bottom-left origin, spanning all displays).
    private func globalPoint(_ local: NSPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
    }

    /// Global AppKit point (bottom-left origin) -> global CoreGraphics point
    /// (top-left origin) used by CGWindowList frames.
    private func cgGlobalPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: totalHeightFlip() - p.y)
    }

    /// The Y value that flips between AppKit (bottom-left) and CoreGraphics
    /// (top-left) global coordinate spaces: the union of all screens' max-Y.
    private func totalHeightFlip() -> CGFloat {
        NSScreen.screens.map { $0.frame.maxY }.max() ?? screenFrame.maxY
    }

    /// CGWindow global frame (top-left origin) -> this view's local rect
    /// (bottom-left origin). Used to highlight a hovered window.
    private func localRect(forCGWindow frame: CGRect) -> CGRect {
        let flip = totalHeightFlip()
        let globalBottomLeftY = flip - frame.maxY
        return CGRect(
            x: frame.minX - screenFrame.minX,
            y: globalBottomLeftY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    /// CGWindow global frame (top-left origin) -> global AppKit screen frame
    /// (bottom-left origin) returned to the coordinator for overlay placement.
    private func globalScreenFrame(forCGWindow frame: CGRect) -> CGRect {
        let flip = totalHeightFlip()
        return CGRect(x: frame.minX, y: flip - frame.maxY, width: frame.width, height: frame.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // The frozen still is the whole display in pixels; `bounds` is the screen
        // size in points. Drawing into `bounds` scales the pixel image down to
        // points, which is correct.
        ctx.draw(frozen, in: bounds)
        // Dim everything.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)

        switch mode {
        case .region:
            if !currentRect.isEmpty {
                // Punch the selection back to full brightness by re-drawing the
                // bright frozen image clipped to the selection only.
                ctx.saveGState()
                ctx.clip(to: currentRect)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
                drawSelectionChrome(currentRect, ctx: ctx)
            }
        case .window:
            if let win = hoveredWindow {
                let local = localRect(forCGWindow: win.frame)
                ctx.saveGState()
                ctx.clip(to: local)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
                drawSelectionChrome(local, ctx: ctx)
            }
        case .fullscreen:
            break
        }
    }

    private func drawSelectionChrome(_ rect: CGRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)
        let label = SelectionGeometry.formatDimensions(rect.size) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: rect.minX, y: rect.maxY + 4, width: size.width + 8, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fill(bg)
        label.draw(at: NSPoint(x: bg.minX + 4, y: bg.minY + 2), withAttributes: attrs)
    }

    // MARK: - Mouse / keyboard

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = SelectionGeometry.clamped(
            SelectionGeometry.normalizedRect(from: start, to: p),
            to: bounds
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            guard !SelectionGeometry.isTooSmall(currentRect) else { onCancel?(); return }
            commitRegion(currentRect)
        case .window:
            guard let win = hoveredWindow else { onCancel?(); return }
            onWindow?(win.id, globalScreenFrame(forCGWindow: win.frame))
        case .fullscreen:
            onCancel?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let local = convert(event.locationInWindow, from: nil)
        hoveredWindow = WindowEnumerator.window(under: cgGlobalPoint(globalPoint(local)), in: windows)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
    }

    // MARK: - Commit

    private func commitRegion(_ rect: CGRect) {
        // Convert the selection from view points (bottom-left) into the frozen
        // image's pixel space (top-left) using the display's backing scale.
        let scale = backingScale
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: (bounds.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard let cropped = frozen.cropping(to: pixelRect) else { onCancel?(); return }
        onRegion?(cropped, CGRect(origin: globalPoint(rect.origin), size: rect.size))
    }
}

extension NSScreen {
    static var screenUnderMouse: NSScreen? {
        let loc = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(loc) }
    }

    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
