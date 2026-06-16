import AppKit
import SwiftUI

/// Observable editor state shared between the SwiftUI chrome and the AppKit canvas.
@MainActor
@Observable
final class AnnotationEditorModel {
    let document: AnnotationDocument
    var tool: AnnotationTool = .arrow
    var style: AnnotationStyle = .default
    /// Bumped on every document mutation so SwiftUI re-reads `canUndo`/`canRedo`
    /// and the canvas redraws after external changes (undo, tool/style switches).
    var revision: Int = 0

    init(image: CGImage) {
        self.document = AnnotationDocument(baseImage: image)
    }

    var canUndo: Bool { document.canUndo }
    var canRedo: Bool { document.canRedo }

    func undo() { document.undo(); revision += 1 }
    func redo() { document.redo(); revision += 1 }
    func noteMutation() { revision += 1 }

    /// The exported image (crop applied), for copy / save / pin / done.
    func exportImage() -> NSImage? { AnnotationRenderer.renderImage(document) }
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
    private var pendingCrop: CGRect?          // in full-image space, during a crop drag
    private var activeTextField: NSTextField?
    private var lastRevision = -1

    init(model: AnnotationEditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func syncFromModel() {
        if lastRevision != model.revision {
            lastRevision = model.revision
            needsDisplay = true
        }
        // Cursor hint per tool.
        switch model.tool {
        case .select: NSCursor.arrow.set()
        case .text: NSCursor.iBeam.set()
        default: NSCursor.crosshair.set()
        }
    }

    private var imageSize: CGSize {
        CGSize(width: model.document.baseImage.width, height: model.document.baseImage.height)
    }

    /// The full-image-space region currently displayed: the committed crop, or the
    /// whole image. The canvas zooms to fit this region, so a crop "takes effect"
    /// live instead of only on export. Undo clears the crop and restores the view.
    private var shownRect: CGRect {
        model.document.cropRect ?? CGRect(origin: .zero, size: imageSize)
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
        // Render with the crop applied so the committed crop shows live (zoomed to
        // fit). `shownRect` already accounts for the crop, so the rendered image maps
        // 1:1 onto `fitted`.
        if let cg = AnnotationRenderer.render(model.document, applyCrop: true) {
            NSImage(cgImage: cg, size: shownRect.size).draw(in: fitted)
        }
        // While dragging the crop tool, dim outside the pending selection to preview
        // what will remain. The crop commits (the canvas zooms) on mouse-up.
        if let crop = pendingCrop, crop.width >= 1, crop.height >= 1 {
            let cropView = imageRectToView(crop, fitted: fitted)
            NSColor.black.withAlphaComponent(0.45).setFill()
            let outside = NSBezierPath(rect: fitted)
            outside.append(NSBezierPath(rect: cropView).reversed)
            outside.fill()
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: cropView)
            border.lineWidth = 1.5
            border.stroke()
        }
    }

    private func imageRectToView(_ rect: CGRect, fitted: CGRect) -> CGRect {
        AnnotationGeometry.imageToViewRect(rect, fitted: fitted, shownRect: shownRect)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        commitActiveText()
        let p = toImage(convert(event.locationInWindow, from: nil))
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
            // Hold the in-progress selection locally so the committed crop (what the
            // canvas shows) doesn't zoom mid-drag; it commits on mouse-up.
            dragOrigin = p
            pendingCrop = CGRect(origin: p, size: .zero)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
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
            if let o = dragOrigin { pendingCrop = AnnotationGeometry.clampCrop(normRect(o, p), to: shownRect) }
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
        switch model.tool {
        case .arrow, .line, .rectangle, .ellipse, .blur, .pixelate, .redaction:
            // Discard a zero-size create drag (a stray click): rollback the add.
            if let last = model.document.elements.last, isDegenerate(last.kind) {
                model.document.rollback()
            }
        case .crop:
            // Commit a meaningful selection; ignore a stray click. Undo reverts it.
            if let pc = pendingCrop, pc.width >= 3, pc.height >= 3 {
                model.document.setCrop(pc)
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
        pendingCrop = nil
        model.noteMutation()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
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
