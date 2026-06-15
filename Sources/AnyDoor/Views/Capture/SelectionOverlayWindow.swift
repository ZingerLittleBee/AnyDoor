import AppKit
import CoreGraphics
import SwiftUI

/// Presents a full-screen, non-activating selection overlay over a pre-captured
/// display, letting the user pick either a region (drag a rectangle, cropped from
/// the supplied frozen still) or a window (highlight + click). Calls `completion`
/// exactly once with a `SelectionResult`, then tears the panel down.
///
/// `present` is deliberately **synchronous** and takes the frozen still as a
/// parameter: the ScreenCaptureKit grab is performed by `CaptureCoordinator` in a
/// nonisolated frame *before* this runs, so no `@MainActor` frame ever awaits the
/// SCK call (which would corrupt the main thread's executor tracking on Swift 6.3
/// — see `CaptureCoordinator.capture(_:)` and swiftlang/swift#89214).
@MainActor
final class SelectionOverlayWindow {
    private var panels: [NSPanel] = []
    private var completion: ((SelectionResult) -> Void)?

    /// Presents a selection overlay on every supplied display (each backed by its
    /// own frozen still), so the user can select on any screen — not just the one
    /// under the cursor at trigger time. The first view to commit/cancel tears the
    /// whole set down. A cross-display rectangle is not supported: each overlay
    /// clamps its selection to its own screen.
    func present(
        targets: [TargetDisplay],
        mode: CaptureMode,
        frozen: [CGDirectDisplayID: CGImage],
        initialRect: CGRect = .zero,
        completion: @escaping (SelectionResult) -> Void
    ) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation

        for target in targets {
            guard let frozenImage = frozen[target.id] else { continue }

            let p = SelectionPanel(
                contentRect: target.frame,
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
            // No appear/disappear animation: a full-screen frozen still otherwise
            // scale-fades in, which reads as the whole screen briefly zooming.
            p.animationBehavior = .none
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            // The reused rect arrives in global AppKit coordinates; pre-draw it
            // only on the display that actually contains it.
            let localInitial: CGRect = (!initialRect.isEmpty && target.frame.contains(CGPoint(x: initialRect.midX, y: initialRect.midY)))
                ? CGRect(x: initialRect.minX - target.frame.minX,
                         y: initialRect.minY - target.frame.minY,
                         width: initialRect.width, height: initialRect.height)
                : .zero
            let view = SelectionOverlayView(
                mode: mode,
                screenFrame: target.frame,
                backingScale: target.backingScale,
                frozen: frozenImage,
                initialRect: localInitial
            )
            view.onRegion = { [weak self] image, rect in self?.finish(.region(image: image, rect: rect)) }
            view.onWindow = { [weak self] id, frame in self?.finish(.window(id: id, frame: frame)) }
            view.onFullscreen = { [weak self] image, frame in self?.finish(.fullscreen(image: image, frame: frame)) }
            view.onScrolling = { [weak self] rect in self?.finish(.scrolling(rect: rect)) }
            view.onRecording = { [weak self] rect in self?.finish(.recording(rect: rect)) }
            view.onCancel = { [weak self] in self?.finish(.cancelled) }
            p.contentView = view
            p.orderFrontRegardless()
            // Key the panel that shows the initial selection (so Enter/Esc/arrows
            // reach it); fall back to the panel under the cursor.
            let keyAnchor = initialRect.isEmpty ? mouse : CGPoint(x: initialRect.midX, y: initialRect.midY)
            if target.frame.contains(keyAnchor) {
                p.makeKeyAndOrderFront(nil)
                p.makeFirstResponder(view)
            }
            panels.append(p)
        }
        // Fall back to keying the first panel if the anchor was off all displays.
        if !panels.contains(where: { $0.isKeyWindow }), let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
    }

    private func finish(_ result: SelectionResult) {
        for p in panels { p.orderOut(nil) }
        panels.removeAll()
        let c = completion
        completion = nil
        c?(result)
    }
}

/// Borderless panel that may become key, so the selection overlay can receive
/// Esc / arrow-key events without activating the app.
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class SelectionOverlayView: NSView {
    var onRegion: ((CGImage, CGRect) -> Void)?
    var onWindow: ((CGWindowID, CGRect) -> Void)?
    var onFullscreen: ((CGImage, CGRect) -> Void)?
    var onScrolling: ((CGRect) -> Void)?
    var onRecording: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var mode: CaptureMode
    private let initialMode: CaptureMode
    private let screenFrame: CGRect
    private let backingScale: CGFloat
    private let frozen: CGImage
    private var windows: [CapturableWindow]

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    private var hoveredWindow: CapturableWindow?
    private var mouseLocation: CGPoint

    /// The attached toolbar (region/window/fullscreen), hosted as a subview and
    /// repositioned below the selection on every change. Only built for an overlay
    /// whose initial mode is `.region` (the unified entry); the standalone window
    /// overlay has no toolbar.
    private var toolbarHost: NSHostingView<CaptureSelectionToolbar>?
    private static let toolbarGap: CGFloat = 10

    /// Active mouse interaction for region mode.
    private enum DragMode: Equatable { case none, creating, moving, resizing(SelectionHandle) }
    private var dragMode: DragMode = .none
    /// Mouse point and rect captured at mouse-down, for move/resize math.
    private var dragOrigin: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero

    /// Handle sizes: a small drawn square, a larger invisible grab area.
    private static let handleVisualSize: CGFloat = 8
    private static let handleHitSize: CGFloat = 16

    private var isCreatingDrag: Bool { dragMode == .creating }
    private var showsLoupe: Bool {
        switch dragMode {
        case .creating: return true
        case .resizing: return true
        case .none, .moving: return false
        }
    }

    /// Magnifier loupe dimensions, in points.
    private static let loupeSize: CGFloat = 120
    private static let loupeSourcePoints: CGFloat = 24

    init(mode: CaptureMode, screenFrame: CGRect, backingScale: CGFloat, frozen: CGImage, initialRect: CGRect = .zero) {
        self.mode = mode
        self.initialMode = mode
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        self.frozen = frozen
        self.windows = mode == .window ? WindowEnumerator.onScreenWindows() : []
        self.currentRect = (mode == .region) ? initialRect : .zero
        self.mouseLocation = CGPoint(x: screenFrame.width / 2, y: screenFrame.height / 2)
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        NSCursor.crosshair.set()
        // Build the attached toolbar only for the unified region entry; the
        // standalone window overlay has no toolbar.
        if mode == .region {
            let host = NSHostingView(rootView: CaptureSelectionToolbar(active: .region) { [weak self] picked in
                self?.toolbarPicked(picked)
            })
            host.translatesAutoresizingMaskIntoConstraints = true   // we set .frame manually
            addSubview(host)
            toolbarHost = host
        }
        layoutToolbar()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }

    // Keep the crosshair cursor while the pointer is over the overlay; AppKit
    // otherwise resets it to the arrow as the mouse moves.
    override func resetCursorRects() {
        // Cursor is managed in `mouseMoved` (crosshair vs. resize vs. move).
    }

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
                drawHandles(currentRect, ctx: ctx)
            }
            // The crosshair guides a fresh drag; the loupe aids precise creating
            // and resizing. Neither shows while idle or moving a pre-shown rect.
            if isCreatingDrag { drawCrosshair(at: mouseLocation, ctx: ctx) }
            if showsLoupe { drawLoupe(at: mouseLocation, ctx: ctx) }
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

    private func drawHandles(_ rect: CGRect, ctx: CGContext) {
        let rects = SelectionGeometry.handleRects(for: rect, handleSize: Self.handleVisualSize)
        for handle in SelectionHandle.allCases {
            guard let hr = rects[handle] else { continue }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hr)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(hr)
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

    /// Thin full-width/height guide lines through the cursor.
    private func drawCrosshair(at point: CGPoint, ctx: CGContext) {
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: bounds.minX, y: point.y))
        ctx.addLine(to: CGPoint(x: bounds.maxX, y: point.y))
        ctx.move(to: CGPoint(x: point.x, y: bounds.minY))
        ctx.addLine(to: CGPoint(x: point.x, y: bounds.maxY))
        ctx.strokePath()
    }

    /// A magnified square of the frozen pixels around the cursor, with a center
    /// crosshair and the cursor's pixel coordinate readout.
    private func drawLoupe(at point: CGPoint, ctx: CGContext) {
        let frame = SelectionGeometry.loupeFrame(
            near: point, loupeSize: Self.loupeSize, gap: 16, in: bounds
        )
        let scale = backingScale
        let srcPts = Self.loupeSourcePoints
        let half = srcPts / 2
        // Source rect in the frozen image's pixel space (top-left origin).
        let srcRect = CGRect(
            x: (point.x - half) * scale,
            y: (bounds.height - point.y - half) * scale,
            width: srcPts * scale,
            height: srcPts * scale
        )
        ctx.saveGState()
        let clip = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(clip)
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(frame)
        if let crop = frozen.cropping(to: srcRect) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: frame)
        }
        // Center crosshair inside the loupe.
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: frame.midX - half, y: frame.midY - half, width: srcPts, height: srcPts))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: frame.midX, y: frame.minY))
        ctx.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
        ctx.move(to: CGPoint(x: frame.minX, y: frame.midY))
        ctx.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
        ctx.strokePath()
        ctx.restoreGState()
        // Border.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(clip)
        ctx.strokePath()
        // Pixel coordinate readout under the loupe.
        let px = Int((point.x * scale).rounded())
        let py = Int(((bounds.height - point.y) * scale).rounded())
        let label = "\(px), \(py)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let lsize = label.size(withAttributes: attrs)
        let bg = CGRect(x: frame.midX - lsize.width / 2 - 4, y: frame.minY - lsize.height - 6,
                        width: lsize.width + 8, height: lsize.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fill(bg)
        label.draw(at: NSPoint(x: bg.minX + 4, y: bg.minY + 2), withAttributes: attrs)
    }

    // MARK: - Mouse / keyboard

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        dragOrigin = p
        rectAtDragStart = currentRect

        if currentRect.isEmpty {
            beginCreating(at: p)
        } else {
            switch SelectionGeometry.hitTest(p, in: currentRect, handleSize: Self.handleHitSize) {
            case .handle(let h): dragMode = .resizing(h)
            case .inside: dragMode = .moving
            case .outside: beginCreating(at: p)
            }
        }
        needsDisplay = true
        layoutToolbar()
    }

    private func beginCreating(at p: CGPoint) {
        dragMode = .creating
        dragStart = p
        currentRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        switch dragMode {
        case .creating:
            guard let start = dragStart else { return }
            currentRect = SelectionGeometry.clamped(SelectionGeometry.normalizedRect(from: start, to: p), to: bounds)
        case .moving:
            NSCursor.closedHand.set()
            currentRect = SelectionGeometry.moved(rectAtDragStart, dx: p.x - dragOrigin.x, dy: p.y - dragOrigin.y, in: bounds)
        case .resizing(let h):
            currentRect = SelectionGeometry.resizing(rectAtDragStart, handle: h, to: p, in: bounds, minSize: SelectionGeometry.minimumEdge)
        case .none:
            break
        }
        needsDisplay = true
        layoutToolbar()
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            let wasCreating = isCreatingDrag
            dragMode = .none
            // A too-small fresh drag resets to empty so the user can retry; an
            // adjusted pre-shown rect is kept. Commit happens on Enter (Phase 1).
            if wasCreating, SelectionGeometry.isTooSmall(currentRect) { currentRect = .zero }
            needsDisplay = true
            layoutToolbar()
        case .window:
            guard let win = hoveredWindow else { onCancel?(); return }
            onWindow?(win.id, globalScreenFrame(forCGWindow: win.frame))
        case .fullscreen:
            onCancel?()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        mouseLocation = local
        // The toolbar is a SwiftUI subview, but this view's full-bounds tracking
        // area still fires here, so it would otherwise force the selection
        // crosshair over the buttons. Show a pointer cursor over the toolbar.
        if let host = toolbarHost, !host.isHidden, host.frame.contains(local) {
            NSCursor.pointingHand.set()
        } else if mode == .window {
            hoveredWindow = WindowEnumerator.window(under: cgGlobalPoint(globalPoint(local)), in: windows)
        } else if mode == .region, !currentRect.isEmpty {
            updateCursor(for: SelectionGeometry.hitTest(local, in: currentRect, handleSize: Self.handleHitSize))
        }
        needsDisplay = true
    }

    /// Best-effort resize/move cursors. AppKit has no public diagonal resize
    /// cursor, so corners fall back to the crosshair.
    private func updateCursor(for hit: SelectionHit) {
        switch hit {
        case .handle(.left), .handle(.right): NSCursor.resizeLeftRight.set()
        case .handle(.top), .handle(.bottom): NSCursor.resizeUpDown.set()
        case .handle: NSCursor.crosshair.set()
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.crosshair.set()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            if mode == .window && initialMode == .region {
                exitToRegionMode()   // return to region instead of cancelling
            } else {
                onCancel?()
            }
        case 36, 76: // Return / keypad Enter — commit a reused or nudged selection
            guard mode == .region, !SelectionGeometry.isTooSmall(currentRect) else { return }
            commitRegion(currentRect)
        case 123, 124, 125, 126: // arrow keys nudge/resize an existing selection
            handleArrowKey(event)
        default:
            break
        }
    }

    /// Arrow keys move the selection (Shift = 10pt steps); holding Option resizes
    /// it from the origin instead. No-op until a selection exists.
    private func handleArrowKey(_ event: NSEvent) {
        guard mode == .region, !currentRect.isEmpty else { return }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let resize = event.modifierFlags.contains(.option)
        var dx: CGFloat = 0, dy: CGFloat = 0
        switch event.keyCode {
        case 123: dx = -step // left
        case 124: dx = step  // right
        case 125: dy = -step // down
        case 126: dy = step  // up
        default: break
        }
        if resize {
            currentRect = SelectionGeometry.resized(currentRect, dw: dx, dh: dy, in: bounds)
        } else {
            currentRect = SelectionGeometry.moved(currentRect, dx: dx, dy: dy, in: bounds)
        }
        needsDisplay = true
        layoutToolbar()
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

    // MARK: - Attached toolbar

    /// Position the toolbar below the current selection (flipping above near the
    /// screen bottom) and hide it unless a region selection is being shown.
    private func layoutToolbar() {
        guard let host = toolbarHost else { return }
        let show = (mode == .region) && !currentRect.isEmpty
        host.isHidden = !show
        guard show else { return }
        let size = host.fittingSize
        host.frame = OverlayPlacement.frame(
            forRegion: currentRect, overlaySize: size, onScreen: bounds, gap: Self.toolbarGap
        )
    }

    /// Dispatch a toolbar button: commit the current region, return the frozen
    /// still for fullscreen, switch the live overlay into window-pick, or hand the
    /// current rect (global AppKit coords) to the scrolling/recording coordinators.
    private func toolbarPicked(_ tool: CaptureToolType) {
        switch tool {
        case .region:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            commitRegion(currentRect)
        case .fullscreen:
            // The frozen still is the clean full display; return it directly.
            onFullscreen?(frozen, CGRect(origin: globalPoint(.zero), size: bounds.size))
        case .window:
            enterWindowSubMode()
        case .scrolling:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            onScrolling?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
        case .recording:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            onRecording?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
        }
    }

    /// Toolbar "window" → switch the live overlay into window-pick: hide the rect +
    /// toolbar, enumerate windows, highlight on hover, commit on click.
    private func enterWindowSubMode() {
        windows = WindowEnumerator.onScreenWindows()
        mode = .window
        hoveredWindow = nil
        layoutToolbar()     // hides the toolbar (mode != .region)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    /// Esc from a toolbar-entered window sub-mode returns to region selection.
    private func exitToRegionMode() {
        mode = .region
        hoveredWindow = nil
        layoutToolbar()     // re-shows the toolbar
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        layoutToolbar()
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
