import AppKit
import CoreGraphics
import SwiftUI

/// Presents a full-screen, non-activating selection overlay over a pre-captured
/// display, letting the user pick either a region (drag a rectangle, cropped from
/// the supplied frozen still) or a window (highlight + click). Calls `completion`
/// exactly once with a `SelectionResult`, then tears the panel down.
///
/// `present` stays synchronous and takes the frozen still captured by
/// `CaptureCoordinator` before any overlay appears. Only target resolution is
/// asynchronous; image capture continues through `LegacyScreenCapture`.
@MainActor
final class SelectionOverlayWindow {
    private var panels: [NSPanel] = []
    private var completion: ((SelectionResult) -> Void)?
    private let targetResolver: any SmartCaptureTargetResolving

    init(targetResolver: any SmartCaptureTargetResolving = AccessibilityCaptureTargetResolver()) {
        self.targetResolver = targetResolver
    }

    /// Presents a selection overlay on every supplied display (each backed by its
    /// own frozen still), so the user can select on any screen — not just the one
    /// under the cursor at trigger time. The first view to commit/cancel tears the
    /// whole set down. A cross-display rectangle is not supported: each overlay
    /// clamps its selection to its own screen. Only the unified screenshot
    /// entry opts into element hover; explicit viewport callers keep free-region
    /// selection even on displays without an initial rectangle.
    func present(
        targets: [TargetDisplay],
        mode: CaptureMode,
        frozen: [CGDirectDisplayID: CGImage],
        initialRect: CGRect = .zero,
        allowsElementSelection: Bool = false,
        completion: @escaping (SelectionResult) -> Void
    ) {
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        // Snapshot before showing any overlay; every display uses the same
        // foreground ordering and the resolver never queries our frozen panels.
        let windows = WindowEnumerator.onScreenWindows()

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
                initialRect: localInitial,
                allowsElementSelection: allowsElementSelection,
                windows: windows,
                targetResolver: targetResolver
            )
            view.onRegion = { [weak self] image, rect in self?.finish(.region(image: image, rect: rect)) }
            view.onWindow = { [weak self] id, frame in self?.finish(.window(id: id, frame: frame)) }
            view.onFullscreen = { [weak self] image, frame in self?.finish(.fullscreen(image: image, frame: frame)) }
            view.onRegionTimer = { [weak self] rect in self?.finish(.regionTimer(rect: rect)) }
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
        guard !panels.isEmpty else { finish(.cancelled); return }
        // Fall back to keying the first panel if the anchor was off all displays.
        if !panels.contains(where: { $0.isKeyWindow }), let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
        for panel in panels {
            (panel.contentView as? SelectionOverlayView)?.resolveInitialHover()
        }
    }

    private func finish(_ result: SelectionResult) {
        for p in panels {
            (p.contentView as? SelectionOverlayView)?.stopResolving()
            p.orderOut(nil)
        }
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
    var onRegionTimer: ((CGRect) -> Void)?
    var onScrolling: ((CGRect) -> Void)?
    var onRecording: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var mode: CaptureMode
    private let initialMode: CaptureMode
    private let screenFrame: CGRect
    private let backingScale: CGFloat
    private let frozen: CGImage
    private let windows: [CapturableWindow]
    private let allowsElementSelection: Bool

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    private let hoverController: SmartCaptureHoverController
    private var smartSelection = SmartCaptureSelection()
    private var fallbackReason: SmartCaptureResolution.FallbackReason?
    private var lastHoverPoint: CGPoint?
    private var mouseLocation: CGPoint

    private var hoverMode: SmartCaptureSelection.HoverMode? {
        SmartCaptureSelection.hoverMode(
            mode: mode, allowsElementSelection: allowsElementSelection,
            hasRegion: !currentRect.isEmpty, isDragging: dragMode != .none
        )
    }
    private var isSmartHover: Bool { hoverMode != nil }

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

    init(
        mode: CaptureMode,
        screenFrame: CGRect,
        backingScale: CGFloat,
        frozen: CGImage,
        initialRect: CGRect = .zero,
        allowsElementSelection: Bool,
        windows: [CapturableWindow],
        targetResolver: any SmartCaptureTargetResolving
    ) {
        self.mode = mode
        self.initialMode = mode
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        self.frozen = frozen
        self.allowsElementSelection = allowsElementSelection
        self.windows = windows
        self.hoverController = SmartCaptureHoverController(resolver: targetResolver)
        self.currentRect = (mode == .region) ? initialRect : .zero
        self.mouseLocation = CGPoint(x: screenFrame.width / 2, y: screenFrame.height / 2)
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverController.onResolution = { [weak self] resolution in
            guard let self, self.isSmartHover, self.smartSelection.pressOrigin == nil else { return }
            self.smartSelection.update(targets: resolution.targets)
            self.fallbackReason = resolution.fallbackReason
            self.needsDisplay = true
        }
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

    func resolveInitialHover() {
        let point = NSEvent.mouseLocation
        guard screenFrame.contains(point) else { return }
        requestHover(at: CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY))
    }

    func stopResolving() {
        hoverController.cancel()
        smartSelection.reset()
        fallbackReason = nil
        lastHoverPoint = nil
    }

    private func requestHover(at local: CGPoint) {
        guard isSmartHover, smartSelection.pressOrigin == nil else { return }
        if local != lastHoverPoint {
            // Never let a click capture the candidate from an older pointer
            // location while the next AX query is still in flight.
            smartSelection.update(targets: [])
            fallbackReason = nil
            lastHoverPoint = local
        }
        mouseLocation = local
        if hoverMode == .window {
            // An explicit Window toolbar/action request retains whole-window
            // capture. Element-level selection belongs to the unified entry.
            let window = WindowEnumerator.window(under: cgGlobalPoint(globalPoint(local)), in: windows)
            smartSelection.update(targets: window.map {
                [SmartCaptureTarget(kind: .window(id: $0.id), globalFrame: $0.frame)]
            } ?? [])
            needsDisplay = true
            return
        }
        hoverController.request(
            at: cgGlobalPoint(globalPoint(local)),
            screenFrame: SelectionGeometry.cgGlobalRect(fromAppKit: screenFrame, flipHeight: totalHeightFlip()),
            windows: windows
        )
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        // Keyboard hierarchy navigation must follow the pointer across displays.
        window?.makeKey()
        window?.makeFirstResponder(self)
        requestHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        guard smartSelection.pressOrigin == nil else { return }
        stopResolving()
        needsDisplay = true
    }

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
    /// (top-left) global coordinate spaces: the PRIMARY display's height (the
    /// CoreGraphics global origin is anchored at the primary display's top), NOT
    /// the union of all screens' max-Y — a secondary display extending above the
    /// primary must not change the constant. Matches `ScrollCaptureSession`.
    private func totalHeightFlip() -> CGFloat {
        SelectionGeometry.globalFlipHeight(
            screenFrames: NSScreen.screens.map { $0.frame }, fallback: screenFrame.maxY
        )
    }

    /// CGWindow global frame (top-left origin) -> this view's local rect
    /// (bottom-left origin). Used to highlight a hovered window.
    private func localRect(forCGWindow frame: CGRect) -> CGRect {
        SelectionGeometry.localRect(fromCG: frame, screenFrame: screenFrame, flipHeight: totalHeightFlip())
    }

    /// CGWindow global frame (top-left origin) -> global AppKit screen frame
    /// (bottom-left origin) returned to the coordinator for overlay placement.
    private func globalScreenFrame(forCGWindow frame: CGRect) -> CGRect {
        SelectionGeometry.appKitGlobalRect(fromCG: frame, flipHeight: totalHeightFlip())
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

        if isSmartHover {
            if let target = smartSelection.selectedTarget {
                let local = localRect(forCGWindow: target.globalFrame).intersection(bounds)
                ctx.saveGState()
                ctx.clip(to: local)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
                drawSelectionChrome(local, ctx: ctx)
            }
            drawSmartHint(ctx: ctx)
            return
        }

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
            break
        case .fullscreen:
            break
        }
    }

    private func drawSmartHint(ctx: CGContext) {
        let key: L10n.Key
        if mode == .window {
            key = .captureWindowHint
        } else {
            switch fallbackReason {
            case .accessibilityPermissionRequired: key = .captureSmartPermissionHint
            case .noUsefulAccessibilityGeometry: key = .captureSmartFallbackHint
            case nil: key = .captureSmartHint
            }
        }
        let label = L(key) as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
        let width = max(1, min(700, bounds.width - 48))
        let size = label.boundingRect(
            with: CGSize(width: width, height: 100), options: [.usesLineFragmentOrigin], attributes: attrs
        ).size
        let frame = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.minY + 24,
                           width: size.width + 24, height: ceil(size.height) + 16)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        label.draw(in: frame.insetBy(dx: 12, dy: 8), withAttributes: attrs)
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
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        dragOrigin = p
        rectAtDragStart = currentRect

        if isSmartHover {
            // A coalesced final mouseMoved must not leave a stale hit under a
            // click at a different point. Window-only picking refreshes here
            // synchronously; element picking waits for the new resolution.
            if p != lastHoverPoint { requestHover(at: p) }
            smartSelection.beginPress(at: p)
            hoverController.cancel()
            return
        }
        guard mode == .region else { return }

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
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        if let origin = smartSelection.pressOrigin {
            guard smartSelection.drag(to: p) else { return }
            if dragMode == .none {
                mode = .region
                beginCreating(at: origin)
                fallbackReason = nil
            }
        }
        guard mode == .region else { return }
        switch dragMode {
        case .creating:
            guard let start = dragStart else { return }
            currentRect = SelectionGeometry.clamped(SelectionGeometry.normalizedRect(from: start, to: p), to: bounds)
        case .moving:
            NSCursor.closedHand.set()
            currentRect = SelectionGeometry.moved(rectAtDragStart, dx: p.x - dragOrigin.x, dy: p.y - dragOrigin.y, in: bounds)
        case .resizing(let h):
            // Keep the matching resize cursor while dragging (mouseMoved is not
            // delivered during a drag, so it would otherwise reset).
            cursor(for: .handle(h)).set()
            currentRect = SelectionGeometry.resizing(rectAtDragStart, handle: h, to: p, in: bounds, minSize: SelectionGeometry.minimumEdge)
        case .none:
            break
        }
        needsDisplay = true
        layoutToolbar()
    }

    override func mouseUp(with event: NSEvent) {
        // Coalesced mouse events may omit the final drag point. Evaluate the
        // release location too, before deciding between a click and a region.
        if smartSelection.pressOrigin != nil || dragMode != .none {
            mouseDragged(with: event)
        }
        if smartSelection.pressOrigin != nil {
            switch smartSelection.release(at: convert(event.locationInWindow, from: nil)) {
            case .target(let target):
                commitTarget(target)
                return
            case .none:
                lastHoverPoint = nil
                requestHover(at: convert(event.locationInWindow, from: nil))
                return
            case .region:
                break // Finish the free-region gesture below, never snap back.
            }
        }
        switch mode {
        case .region:
            let wasCreating = isCreatingDrag
            dragMode = .none
            // A too-small fresh drag resets to empty so the user can retry; an
            // adjusted pre-shown rect is kept. Commit happens on Enter (Phase 1).
            if wasCreating, SelectionGeometry.isTooSmall(currentRect) { currentRect = .zero }
            needsDisplay = true
            layoutToolbar()
            if currentRect.isEmpty {
                lastHoverPoint = nil
                requestHover(at: convert(event.locationInWindow, from: nil))
            }
        case .window:
            break
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
        } else if isSmartHover {
            NSCursor.crosshair.set()
            requestHover(at: local)
        } else if mode == .region, !currentRect.isEmpty {
            updateCursor(for: SelectionGeometry.hitTest(local, in: currentRect, handleSize: Self.handleHitSize))
        }
        needsDisplay = true
    }

    private func updateCursor(for hit: SelectionHit) {
        cursor(for: hit).set()
    }

    /// Resize/move cursor for a hit. AppKit exposes no public diagonal resize
    /// cursor, so corner handles use a custom-drawn diagonal double-headed arrow
    /// (`makeDiagonalResizeCursor`); edges and the interior use system cursors.
    private func cursor(for hit: SelectionHit) -> NSCursor {
        switch hit {
        case .handle(.left), .handle(.right): return .resizeLeftRight
        case .handle(.top), .handle(.bottom): return .resizeUpDown
        case .handle(.topLeft), .handle(.bottomRight): return Self.resizeDiagonalNWSE
        case .handle(.topRight), .handle(.bottomLeft): return Self.resizeDiagonalNESW
        case .inside: return .openHand
        case .outside: return .crosshair
        }
    }

    /// Diagonal resize cursors, resolved once and reused. `nwse` points at the
    /// top-left / bottom-right corners (↖↘); `nesw` points at the top-right /
    /// bottom-left corners (↗↙). Prefers the native macOS cursor.
    private static let resizeDiagonalNWSE = systemDiagonalResizeCursor(.nwse)
    private static let resizeDiagonalNESW = systemDiagonalResizeCursor(.nesw)

    private enum DiagonalResize { case nwse, nesw }

    /// macOS's native diagonal resize cursor for `orientation`, obtained through
    /// the long-stable private `NSCursor` class accessors (the app ships
    /// notarized outside the App Store, so private-API use is permitted). Falls
    /// back to a custom-drawn arrow only if the accessor is ever unavailable.
    private static func systemDiagonalResizeCursor(_ orientation: DiagonalResize) -> NSCursor {
        let name = orientation == .nwse
            ? "_windowResizeNorthWestSouthEastCursor"
            : "_windowResizeNorthEastSouthWestCursor"
        let selector = NSSelectorFromString(name)
        if NSCursor.responds(to: selector),
           let cursor = NSCursor.perform(selector)?.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return makeDiagonalResizeCursor(orientation)
    }

    /// Draws a diagonal double-headed resize arrow as an `NSCursor`. The arrow is
    /// a thin black stroke under a white halo — matching the system edge resize
    /// cursors — so it stays visible over both the bright selection and the dim
    /// surrounding overlay. The hot spot is the image center.
    private static func makeDiagonalResizeCursor(_ orientation: DiagonalResize) -> NSCursor {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let inset: CGFloat = 4
            // Shaft endpoints (y-up).
            let a: NSPoint, b: NSPoint
            switch orientation {
            case .nwse:
                a = NSPoint(x: inset, y: side - inset)        // top-left
                b = NSPoint(x: side - inset, y: inset)        // bottom-right
            case .nesw:
                a = NSPoint(x: side - inset, y: side - inset) // top-right
                b = NSPoint(x: inset, y: inset)               // bottom-left
            }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: a)
            path.line(to: b)
            // Open chevron arrowhead at each tip, pointing outward.
            let head: CGFloat = 7
            let theta: CGFloat = 35 * .pi / 180
            for (tip, toward) in [(a, b), (b, a)] {
                let len = max(1, hypot(tip.x - toward.x, tip.y - toward.y))
                let ux = (tip.x - toward.x) / len, uy = (tip.y - toward.y) / len // outward
                for sign: CGFloat in [1, -1] {
                    let c = cos(sign * theta), s = sin(sign * theta)
                    // Reverse the outward direction, then rotate by ±theta.
                    let wx = -ux * c + uy * s
                    let wy = -ux * s - uy * c
                    path.move(to: tip)
                    path.line(to: NSPoint(x: tip.x + wx * head, y: tip.y + wy * head))
                }
            }
            NSColor.white.setStroke()
            path.lineWidth = 3.5
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
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
            if isSmartHover, let target = smartSelection.selectedTarget {
                commitTarget(target)
                return
            }
            guard mode == .region, !SelectionGeometry.isTooSmall(currentRect) else { return }
            commitRegion(currentRect)
        case 48: // Tab / Shift-Tab cycle out to parents or back toward the hit.
            guard isSmartHover else { return }
            smartSelection.cycle(backwards: event.modifierFlags.contains(.shift))
            needsDisplay = true
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

    private func commitTarget(_ target: SmartCaptureTarget) {
        hoverController.cancel()
        switch target.kind {
        case .accessibility:
            // Element captures must use the clean frozen image, not a fresh
            // whole-window grab containing pixels outside the highlighted UI.
            let rect = localRect(forCGWindow: target.globalFrame).intersection(bounds)
            guard !SelectionGeometry.isTooSmall(rect) else { return }
            commitRegion(rect)
        case .window(let id):
            onWindow?(id, globalScreenFrame(forCGWindow: target.globalFrame))
        }
    }

    private func commitRegion(_ rect: CGRect) {
        // Convert the selection from view points (bottom-left) into the frozen
        // image's pixel space (top-left) using the display's backing scale.
        let pixelRect = SelectionGeometry.pixelRect(fromLocal: rect, bounds: bounds, backingScale: backingScale)
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
    /// current rect (global AppKit coords) to the timer/scrolling/recording coordinators.
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
        case .timer:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            onRegionTimer?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
        case .scrolling:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            onScrolling?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
        case .recording:
            guard !SelectionGeometry.isTooSmall(currentRect) else { return }
            onRecording?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
        }
    }

    /// Toolbar "window" → hide the rect/toolbar and pick a whole window from the
    /// pre-overlay snapshot, highlighting on hover and committing on click.
    private func enterWindowSubMode() {
        stopResolving()
        mode = .window
        layoutToolbar()     // hides the toolbar (mode != .region)
        NSCursor.crosshair.set()
        resolveInitialHover()
        needsDisplay = true
    }

    /// Esc from a toolbar-entered window sub-mode returns to region selection.
    private func exitToRegionMode() {
        stopResolving()
        mode = .region
        layoutToolbar()     // re-shows the toolbar
        resolveInitialHover()
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
