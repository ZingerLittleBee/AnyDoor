import AppKit
import SwiftUI

/// Observable editor state shared between the SwiftUI chrome and the AppKit canvas.
@MainActor
@Observable
final class AnnotationEditorModel {
    let document: AnnotationDocument
    private(set) var tool: AnnotationTool = .arrow
    var style: AnnotationStyle = .default
    var cropSession: CropSession?
    /// Bumped on every document mutation so SwiftUI re-reads `canUndo`/`canRedo`
    /// and the canvas redraws after external changes (undo, tool/style switches).
    var revision: Int = 0
    private var toolBeforeCrop: AnnotationTool = .arrow

    /// Set by the AppKit canvas: flushes any in-progress inline text field into the
    /// document. Invoked before every export so text typed but not yet committed
    /// with Return (e.g. when the user clicks Copy/Save/Pin/Done) is not dropped.
    var commitPendingText: (@MainActor () -> Void)?

    init(image: CGImage) {
        self.document = AnnotationDocument(baseImage: image)
    }

    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }
    var isCropSessionActive: Bool { cropSession != nil }
    var cropAspectPreset: CropAspectPreset { cropSession?.aspectPreset ?? .freeform }
    var canFlipCropAspect: Bool { cropSession?.aspectPreset.allowsOrientationFlip ?? false }

    func undo() { document.undo(); noteMutation() }
    func redo() { document.redo(); noteMutation() }
    func noteMutation() { revision += 1 }

    func setTool(_ newTool: AnnotationTool) {
        if newTool == .crop {
            guard cropSession == nil else { return }
            toolBeforeCrop = tool == .crop ? toolBeforeCrop : tool
            tool = .crop
            startCropSession()
            return
        }

        if cropSession != nil {
            cropSession = nil
            tool = newTool
            noteMutation()
            return
        }

        guard tool != newTool else { return }
        tool = newTool
        noteMutation()
    }

    func updateCropRect(_ rect: CGRect) {
        guard var session = cropSession else { return }
        session.rect = CropGeometry.clampRect(rect, to: session.imageBounds)
        cropSession = session
        noteMutation()
    }

    func nudgeCropRect(dx: CGFloat, dy: CGFloat) {
        guard var session = cropSession else { return }
        session.rect = CropGeometry.nudge(rect: session.rect, dx: dx, dy: dy, in: session.imageBounds)
        cropSession = session
        noteMutation()
    }

    func setCropAspectPreset(_ preset: CropAspectPreset) {
        guard var session = cropSession else { return }
        session.aspectPreset = preset
        if !preset.allowsOrientationFlip {
            session.aspectFlipped = false
        }
        if let ratio = session.activeAspectRatio {
            session.rect = CropGeometry.snapAspect(rect: session.rect, ratio: ratio, in: session.imageBounds)
        }
        cropSession = session
        noteMutation()
    }

    func flipCropAspectOrientation() {
        guard var session = cropSession, session.aspectPreset.allowsOrientationFlip else { return }
        session.aspectFlipped.toggle()
        if let ratio = session.activeAspectRatio {
            session.rect = CropGeometry.snapAspect(rect: session.rect, ratio: ratio, in: session.imageBounds)
        }
        cropSession = session
        noteMutation()
    }

    func commitCropSession() {
        guard let session = cropSession else { return }
        let action = CropGeometry.classifyCommit(
            initial: document.cropRect ?? document.imageBounds,
            current: session.rect,
            imageBounds: session.imageBounds
        )
        cropSession = nil
        tool = toolBeforeCrop

        switch action {
        case .noOp:
            break
        case .clear:
            document.clearCrop()
        case let .set(rect):
            document.setCrop(rect)
        }
        noteMutation()
    }

    func cancelCropSession() {
        guard cropSession != nil else { return }
        cropSession = nil
        tool = toolBeforeCrop
        noteMutation()
    }

    private func startCropSession() {
        let initialRect = document.cropRect ?? document.imageBounds
        cropSession = CropSession(initialRect: initialRect, imageBounds: document.imageBounds)
        noteMutation()
    }

    /// The exported image (crop applied), for copy / save / pin / done. Flushes any
    /// in-progress inline text first so uncommitted typing is never lost.
    func exportImage() -> NSImage? {
        commitPendingText?()
        return AnnotationRenderer.renderImage(document)
    }
}

/// SwiftUI wrapper around the AppKit drawing canvas.
struct AnnotationCanvasView: NSViewRepresentable {
    let model: AnnotationEditorModel

    func makeNSView(context: Context) -> CanvasNSView {
        CanvasNSView(model: model)
    }

    func updateNSView(_ nsView: CanvasNSView, context: Context) {
        // Re-read tool/style/revision-driven state and redraw.
        nsView.syncFromModel()
    }
}

/// The interactive drawing surface. Flipped (top-left origin) so view points map
/// cleanly onto image pixel space. Renders the document each draw and overlays the
/// in-progress crop chrome.
final class CanvasNSView: NSView {
    private let model: AnnotationEditorModel
    private var dragOrigin: CGPoint?          // in image space
    private var draggingElementID: UUID?      // select-move target
    private var selectMoveLastPoint: CGPoint? // in image space
    private var selectDidMove = false
    private var pathPoints: [CGPoint] = []
    private var cropDragState: CropDragState?
    private var cropSizeBadgeVisible = false
    private var trackingArea: NSTrackingArea?
    private var lastMouseViewPoint: CGPoint?
    private var activeTextField: NSTextField?
    private var lastRevision = -1
    private var wasCropSessionActive = false

    private enum CropDragState {
        case handle(CropHandle, initialRect: CGRect, presetAspectRatio: CGFloat?)
        case move(initialRect: CGRect, startPoint: CGPoint)
        case newBox(anchor: CGPoint, aspectRatio: CGFloat?)
    }

    init(model: AnnotationEditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        // Let the model flush in-progress inline text before any export. `[weak
        // self]` keeps no retain cycle (the model owns the closure); after the
        // canvas is gone the call is a safe no-op.
        model.commitPendingText = { [weak self] in self?.commitActiveText() }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func syncFromModel() {
        let isCropSessionActive = model.isCropSessionActive
        if isCropSessionActive && !wasCropSessionActive {
            window?.makeFirstResponder(self)
        }
        wasCropSessionActive = isCropSessionActive

        if lastRevision != model.revision {
            lastRevision = model.revision
            needsDisplay = true
        }
        if let lastMouseViewPoint {
            updateCursor(at: lastMouseViewPoint)
            return
        }
        // Cursor hint per tool.
        setToolCursor()
    }

    private var imageSize: CGSize {
        CGSize(width: model.document.baseImage.width, height: model.document.baseImage.height)
    }

    /// The full-image-space region currently displayed: the committed crop, or the
    /// whole image. The canvas zooms to fit this region, so a crop "takes effect"
    /// live instead of only on export. Undo clears the crop and restores the view.
    private var shownRect: CGRect {
        if model.isCropSessionActive {
            return CGRect(origin: .zero, size: imageSize)
        }
        return model.document.cropRect ?? CGRect(origin: .zero, size: imageSize)
    }

    private var fittedRect: CGRect {
        AnnotationGeometry.fittedRect(imageSize: shownRect.size, in: bounds.size)
    }

    private func toImage(_ p: NSPoint) -> CGPoint {
        AnnotationGeometry.viewToImage(p, fitted: fittedRect, shownRect: shownRect)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let fitted = fittedRect
        guard fitted.width > 0 else { return }
        // During crop sessions the full image is shown so a previous crop can be
        // expanded non-destructively. Otherwise the committed crop stays zoomed in.
        if let cg = AnnotationRenderer.render(model.document, applyCrop: !model.isCropSessionActive) {
            NSImage(cgImage: cg, size: shownRect.size).draw(in: fitted)
        }
        if let session = model.cropSession, session.rect.width > 0, session.rect.height > 0 {
            drawCropChrome(session: session, fitted: fitted)
        }
    }

    private func imageRectToView(_ rect: CGRect, fitted: CGRect) -> CGRect {
        AnnotationGeometry.imageToViewRect(rect, fitted: fitted, shownRect: shownRect)
    }

    private func drawCropChrome(session: CropSession, fitted: CGRect) {
        let cropView = imageRectToView(session.rect, fitted: fitted).standardized

        NSColor.black.withAlphaComponent(0.45).setFill()
        let outside = NSBezierPath(rect: fitted)
        outside.append(NSBezierPath(rect: cropView).reversed)
        outside.fill()

        drawRuleOfThirds(in: cropView)

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: cropView)
        border.lineWidth = 1
        border.stroke()

        drawCropHandles(in: cropView)

        if cropSizeBadgeVisible {
            drawCropSizeBadge(for: session.rect, cropView: cropView, fitted: fitted)
        }
    }

    private func drawRuleOfThirds(in rect: CGRect) {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for fraction in [CGFloat(1) / 3, CGFloat(2) / 3] {
            let x = rect.minX + rect.width * fraction
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.line(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * fraction
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.line(to: CGPoint(x: rect.maxX, y: y))
        }
        path.stroke()
    }

    private func drawCropHandles(in rect: CGRect) {
        NSColor.white.setFill()
        let length: CGFloat = 19
        let thickness: CGFloat = 3
        let radius = thickness / 2

        func pill(_ r: CGRect) {
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }

        pill(CGRect(x: rect.minX, y: rect.minY - thickness / 2, width: length, height: thickness))
        pill(CGRect(x: rect.minX - thickness / 2, y: rect.minY, width: thickness, height: length))
        pill(CGRect(x: rect.maxX - length, y: rect.minY - thickness / 2, width: length, height: thickness))
        pill(CGRect(x: rect.maxX - thickness / 2, y: rect.minY, width: thickness, height: length))
        pill(CGRect(x: rect.maxX - length, y: rect.maxY - thickness / 2, width: length, height: thickness))
        pill(CGRect(x: rect.maxX - thickness / 2, y: rect.maxY - length, width: thickness, height: length))
        pill(CGRect(x: rect.minX, y: rect.maxY - thickness / 2, width: length, height: thickness))
        pill(CGRect(x: rect.minX - thickness / 2, y: rect.maxY - length, width: thickness, height: length))

        let edgeLength: CGFloat = 22
        pill(CGRect(x: rect.midX - edgeLength / 2, y: rect.minY - thickness / 2, width: edgeLength, height: thickness))
        pill(CGRect(x: rect.maxX - thickness / 2, y: rect.midY - edgeLength / 2, width: thickness, height: edgeLength))
        pill(CGRect(x: rect.midX - edgeLength / 2, y: rect.maxY - thickness / 2, width: edgeLength, height: thickness))
        pill(CGRect(x: rect.minX - thickness / 2, y: rect.midY - edgeLength / 2, width: thickness, height: edgeLength))
    }

    private func drawCropSizeBadge(for rect: CGRect, cropView: CGRect, fitted: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding = CGSize(width: 9, height: 5)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2, height: textSize.height + padding.height * 2)
        let gap: CGFloat = 8
        var origin = CGPoint(x: cropView.minX, y: cropView.minY - badgeSize.height - gap)
        if origin.y < fitted.minY {
            origin.y = cropView.minY + gap
        }
        if origin.x + badgeSize.width > fitted.maxX - gap {
            origin.x = fitted.maxX - badgeSize.width - gap
        }
        if origin.x < fitted.minX + gap {
            origin.x = fitted.minX + gap
        }
        let badgeRect = CGRect(origin: origin, size: badgeSize)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(
            at: CGPoint(x: badgeRect.minX + padding.width, y: badgeRect.minY + padding.height),
            withAttributes: attributes
        )
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitActiveText()
        let viewPoint = convert(event.locationInWindow, from: nil)
        lastMouseViewPoint = viewPoint
        if beginCropInteraction(at: viewPoint) {
            window?.makeFirstResponder(self)
            return
        }

        let p = toImage(viewPoint)
        let tool = model.tool
        let style = model.style

        switch tool {
        case .counter:
            model.document.addCounter(at: p, style: style)
            model.noteMutation()
            needsDisplay = true
        case .text:
            beginTextEntry(atViewPoint: convert(event.locationInWindow, from: nil), imagePoint: p)
        case .select:
            // Topmost element under the point.
            if let hit = model.document.elements.last(where: { AnnotationGeometry.hitTest(p, element: $0) }) {
                draggingElementID = hit.id
                selectMoveLastPoint = p
                selectDidMove = false
                model.document.beginEdit() // one checkpoint for the whole move
            }
        case .arrow, .line:
            dragOrigin = p
            model.document.add(AnnotationElement(kind: tool == .arrow ? .arrow(from: p, to: p) : .line(from: p, to: p), style: style))
            model.noteMutation()
        case .freehand, .highlighter:
            pathPoints = [p]
            let kind: AnnotationElement.Kind = tool == .freehand ? .freehand(pathPoints) : .highlighter(pathPoints)
            model.document.add(AnnotationElement(kind: kind, style: style))
            model.noteMutation()
        case .rectangle, .ellipse, .blur, .pixelate, .redaction:
            dragOrigin = p
            model.document.add(AnnotationElement(kind: rectKind(tool, CGRect(origin: p, size: .zero)), style: style))
            model.noteMutation()
        case .crop:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        lastMouseViewPoint = viewPoint
        if updateCropInteraction(at: viewPoint, event: event) {
            return
        }

        let p = toImage(viewPoint)
        switch model.tool {
        case .arrow:
            if let o = dragOrigin { model.document.updateLastKind(.arrow(from: o, to: p)) }
        case .line:
            if let o = dragOrigin { model.document.updateLastKind(.line(from: o, to: p)) }
        case .freehand, .highlighter:
            pathPoints.append(p)
            model.document.updateLastKind(model.tool == .freehand ? .freehand(pathPoints) : .highlighter(pathPoints))
        case .rectangle, .ellipse, .blur, .pixelate, .redaction:
            if let o = dragOrigin { model.document.updateLastKind(rectKind(model.tool, normRect(o, p))) }
        case .crop:
            break
        case .select:
            if let id = draggingElementID, let last = selectMoveLastPoint {
                let dx = p.x - last.x, dy = p.y - last.y
                moveElement(id: id, dx: dx, dy: dy)
                selectMoveLastPoint = p
                selectDidMove = true
            }
        case .counter, .text:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if cropDragState != nil {
            endCropInteraction()
            return
        }

        switch model.tool {
        case .arrow, .line, .rectangle, .ellipse, .blur, .pixelate, .redaction:
            // Discard a zero-size create drag (a stray click): rollback the add.
            if let last = model.document.elements.last, isDegenerate(last.kind) {
                model.document.rollback()
            }
        case .select:
            // A grab that never moved rolls back its (empty) checkpoint.
            if draggingElementID != nil, !selectDidMove {
                model.document.rollback()
            }
        default:
            break
        }
        dragOrigin = nil
        draggingElementID = nil
        selectMoveLastPoint = nil
        pathPoints = []
        model.noteMutation()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if handleCropKeyDown(event) {
            return
        }

        // Cmd-Z / Cmd-Shift-Z undo/redo (the canvas owns the keyboard while editing).
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
            needsDisplay = true
            return
        }
        // Delete removes the selected / last element.
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward-delete
            model.document.removeLast()
            model.noteMutation()
            needsDisplay = true
            return
        }
        super.keyDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        lastMouseViewPoint = viewPoint
        updateCursor(at: viewPoint)
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseViewPoint = nil
        NSCursor.arrow.set()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    private func beginCropInteraction(at viewPoint: CGPoint) -> Bool {
        guard let session = model.cropSession else { return false }
        let cropView = imageRectToView(session.rect, fitted: fittedRect)
        let target = CropGeometry.hitTest(point: viewPoint, viewRect: cropView, tolerance: 10)
        let imagePoint = CropGeometry.clampPoint(toImage(viewPoint), to: session.imageBounds)

        switch target {
        case let .handle(handle):
            cropDragState = .handle(handle, initialRect: session.rect, presetAspectRatio: session.activeAspectRatio)
            cropSizeBadgeVisible = true
        case .inside:
            cropDragState = .move(initialRect: session.rect, startPoint: imagePoint)
            cropSizeBadgeVisible = true
            NSCursor.closedHand.set()
        case .outside:
            cropDragState = .newBox(anchor: imagePoint, aspectRatio: session.activeAspectRatio)
            cropSizeBadgeVisible = true
        }
        needsDisplay = true
        return true
    }

    private func updateCropInteraction(at viewPoint: CGPoint, event: NSEvent) -> Bool {
        guard let state = cropDragState, let session = model.cropSession else { return false }
        let imagePoint = CropGeometry.clampPoint(toImage(viewPoint), to: session.imageBounds)
        let next: CGRect
        switch state {
        case let .handle(handle, initialRect, presetAspectRatio):
            let aspectRatio = cropResizeAspectRatio(
                for: handle,
                initialRect: initialRect,
                presetAspectRatio: presetAspectRatio,
                event: event
            )
            next = CropGeometry.resize(
                rect: initialRect,
                handle: handle,
                to: imagePoint,
                in: session.imageBounds,
                aspectRatio: aspectRatio
            )
        case let .move(initialRect, startPoint):
            next = CropGeometry.move(
                rect: initialRect,
                by: CGVector(dx: imagePoint.x - startPoint.x, dy: imagePoint.y - startPoint.y),
                in: session.imageBounds
            )
        case let .newBox(anchor, aspectRatio):
            next = CropGeometry.drawNewRect(anchor: anchor, to: imagePoint, in: session.imageBounds, aspectRatio: aspectRatio)
        }
        model.updateCropRect(next)
        cropSizeBadgeVisible = true
        needsDisplay = true
        return true
    }

    private func cropResizeAspectRatio(
        for handle: CropHandle,
        initialRect: CGRect,
        presetAspectRatio: CGFloat?,
        event: NSEvent
    ) -> CGFloat? {
        if let ratio = presetAspectRatio {
            return ratio
        }
        if handle.isCorner && event.modifierFlags.contains(.shift), initialRect.height > 0 {
            return initialRect.width / initialRect.height
        }
        return nil
    }

    private func handleCropKeyDown(_ event: NSEvent) -> Bool {
        guard model.isCropSessionActive else { return false }
        let hasBypassModifier = event.modifierFlags.contains(.command)
            || event.modifierFlags.contains(.option)
            || event.modifierFlags.contains(.control)

        switch event.keyCode {
        case 36, 76: // Return / keypad Enter
            guard !hasBypassModifier else { return false }
            model.commitCropSession()
            endCropInteraction()
            return true
        case 53: // Esc
            guard !hasBypassModifier else { return false }
            model.cancelCropSession()
            endCropInteraction()
            return true
        case 123, 124, 125, 126:
            guard !hasBypassModifier else { return false }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let delta: CGVector
            switch event.keyCode {
            case 123: delta = CGVector(dx: -step, dy: 0)
            case 124: delta = CGVector(dx: step, dy: 0)
            case 125: delta = CGVector(dx: 0, dy: step)
            default: delta = CGVector(dx: 0, dy: -step)
            }
            model.nudgeCropRect(dx: delta.dx, dy: delta.dy)
            showCropSizeBadgeBriefly()
            needsDisplay = true
            return true
        default:
            return false
        }
    }

    private func endCropInteraction() {
        cropDragState = nil
        cropSizeBadgeVisible = false
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideCropSizeBadge), object: nil)
        if let lastMouseViewPoint {
            updateCursor(at: lastMouseViewPoint)
        }
        needsDisplay = true
    }

    private func showCropSizeBadgeBriefly() {
        cropSizeBadgeVisible = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideCropSizeBadge), object: nil)
        perform(#selector(hideCropSizeBadge), with: nil, afterDelay: 0.8)
    }

    @objc private func hideCropSizeBadge() {
        cropSizeBadgeVisible = false
        needsDisplay = true
    }

    private func updateCursor(at viewPoint: CGPoint) {
        guard let session = model.cropSession else {
            setToolCursor()
            return
        }

        let cropView = imageRectToView(session.rect, fitted: fittedRect)
        switch CropGeometry.hitTest(point: viewPoint, viewRect: cropView, tolerance: 10) {
        case let .handle(handle):
            cursor(for: handle).set()
        case .inside:
            if case .move = cropDragState {
                NSCursor.closedHand.set()
            } else {
                NSCursor.openHand.set()
            }
        case .outside:
            NSCursor.crosshair.set()
        }
    }

    private func setToolCursor() {
        switch model.tool {
        case .select:
            NSCursor.arrow.set()
        case .text:
            NSCursor.iBeam.set()
        default:
            NSCursor.crosshair.set()
        }
    }

    private func cursor(for handle: CropHandle) -> NSCursor {
        if #available(macOS 15, *) {
            return NSCursor.frameResize(position: frameResizePosition(for: handle), directions: .all)
        }
        return .crosshair
    }

    @available(macOS 15, *)
    private func frameResizePosition(for handle: CropHandle) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .right: return .right
        case .bottomRight: return .bottomRight
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeft
        case .left: return .left
        }
    }

    // MARK: - Helpers

    private func rectKind(_ tool: AnnotationTool, _ rect: CGRect) -> AnnotationElement.Kind {
        switch tool {
        case .rectangle: return .rectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .blur: return .blur(rect)
        case .pixelate: return .pixelate(rect)
        case .redaction: return .redaction(rect)
        default: return .rectangle(rect)
        }
    }

    private func normRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func isDegenerate(_ kind: AnnotationElement.Kind) -> Bool {
        switch kind {
        case let .rectangle(r), let .ellipse(r), let .blur(r), let .pixelate(r), let .redaction(r):
            return r.width < 3 || r.height < 3
        case let .arrow(from, to), let .line(from, to):
            return hypot(to.x - from.x, to.y - from.y) < 3
        default:
            return false
        }
    }

    private func moveElement(id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let el = model.document.elements.first(where: { $0.id == id }) else { return }
        let moved = AnnotationCanvasView_translate(el.kind, dx: dx, dy: dy)
        model.document.updateNoCheckpoint(id: id, kind: moved)
    }

    // MARK: - Inline text entry

    private func beginTextEntry(atViewPoint viewPoint: NSPoint, imagePoint: CGPoint) {
        let field = NSTextField(frame: NSRect(x: viewPoint.x, y: viewPoint.y, width: 200, height: 28))
        field.font = NSFont.boldSystemFont(ofSize: model.style.fontSize * (fittedRect.width / shownRect.width))
        field.textColor = model.style.strokeColor.nsColor
        field.backgroundColor = NSColor.white.withAlphaComponent(0.85)
        field.isBordered = true
        field.focusRingType = .none
        field.placeholderString = ""
        field.target = self
        field.action = #selector(commitTextFieldAction)
        field.tag = 0
        addSubview(field)
        window?.makeFirstResponder(field)
        activeTextField = field
        textImageOrigin = imagePoint
    }

    private var textImageOrigin: CGPoint = .zero

    @objc private func commitTextFieldAction() {
        commitActiveText()
    }

    private func commitActiveText() {
        guard let field = activeTextField else { return }
        let text = field.stringValue
        field.removeFromSuperview()
        activeTextField = nil
        guard !text.isEmpty else { return }
        model.document.add(AnnotationElement(kind: .text(text, origin: textImageOrigin), style: model.style))
        model.noteMutation()
        needsDisplay = true
    }
}

/// Translates an element's geometry by (dx, dy) in image space. Free function so it
/// can stay close to the canvas without bloating the document model.
func AnnotationCanvasView_translate(_ kind: AnnotationElement.Kind, dx: CGFloat, dy: CGFloat) -> AnnotationElement.Kind {
    func mp(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
    func mr(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
    switch kind {
    case let .arrow(a, b): return .arrow(from: mp(a), to: mp(b))
    case let .line(a, b): return .line(from: mp(a), to: mp(b))
    case let .rectangle(r): return .rectangle(mr(r))
    case let .ellipse(r): return .ellipse(mr(r))
    case let .freehand(pts): return .freehand(pts.map(mp))
    case let .highlighter(pts): return .highlighter(pts.map(mp))
    case let .text(s, o): return .text(s, origin: mp(o))
    case let .blur(r): return .blur(mr(r))
    case let .pixelate(r): return .pixelate(mr(r))
    case let .redaction(r): return .redaction(mr(r))
    case let .counter(n, c): return .counter(n, center: mp(c))
    }
}
