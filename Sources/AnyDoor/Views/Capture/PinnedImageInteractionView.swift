import AppKit

/// Cursor updates must win after AppKit finishes dispatching the event. Inactive
/// nonactivating panels do not receive active-app cursorUpdate callbacks, and
/// mouseMoved alone can be followed by AppKit resetting the cursor to an arrow.
@MainActor
final class PinnedImagePanel: NSPanel {
    var refreshImageCursor: (@MainActor () -> Void)?
    weak var imageCursorOwner: PinnedImageDragView?

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        refreshCursorAfterDispatch(event)
    }

    func refreshCursorAfterDispatch(_ event: NSEvent) {
        switch event.type {
        case .mouseMoved, .mouseEntered, .cursorUpdate, .leftMouseDragged, .leftMouseUp:
            refreshImageCursor?()
        default:
            break
        }
    }
}

enum PinnedImagePointerStyle: Equatable {
    case move
    case resize(SelectionHandle)
}

/// Owns inside-edge resizing instead of relying on borderless native resizing.
/// Original screen coordinates prevent frame feedback from compounding a drag.
@MainActor
final class PinnedImageDragView: NSView {
    var onHoverChanged: (@MainActor () -> Void)?
    var image: NSImage? { didSet { needsDisplay = true } }
    var isHovered = false { didSet { needsDisplay = true } }
    // A narrow injection seam records actual cursor decisions in tests without
    // pretending that NSCursor.current proves Window Server pointer rendering.
    var applyPointerStyle: (PinnedImagePointerStyle) -> Void = { style in
        switch style {
        case .move: NSCursor.openHand.set()
        case .resize(let handle): PinnedImageResizeCursor.cursor(for: handle).set()
        }
    }
    var cursorContext: () -> (point: CGPoint, frontmostWindowNumber: Int) = {
        let point = NSEvent.mouseLocation
        return (point, NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0))
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var cursorTrackingArea: NSTrackingArea?
    private var resizeGesture: (handle: SelectionHandle, frame: CGRect, start: CGPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.cgContext.clear(bounds)
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        outline.addClip()
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        if let image, image.size.width.isFinite, image.size.height.isFinite,
           image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let destination = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                     width: size.width, height: size.height)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        }
        NSColor.white.withAlphaComponent(isHovered ? 0.6 : 0.2).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9.5, yRadius: 9.5)
        border.lineWidth = 1
        border.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove only our areas. NSView may also own tooltip tracking areas.
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let hover = NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect], owner: self
        )
        let cursor = NSTrackingArea(
            rect: bounds, options: [.activeInActiveApp, .cursorUpdate, .inVisibleRect], owner: self
        )
        addTrackingArea(hover)
        addTrackingArea(cursor)
        hoverTrackingArea = hover
        cursorTrackingArea = cursor
        refreshCursorForCurrentLocation()
    }

    override func resetCursorRects() {
        // Use cursorUpdate plus the panel's after-dispatch fallback, rather than
        // key-window-dependent legacy rectangles competing with tracking areas.
    }

    override func cursorUpdate(with event: NSEvent) {
        // This root owns the entire image. A rejected update is stale or belongs
        // to another window; bubbling it up could reset that window's cursor.
        refreshCursorForCurrentLocation()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?()
        refreshCursorForCurrentLocation()
    }

    override func mouseMoved(with event: NSEvent) { refreshCursorForCurrentLocation() }

    override func mouseExited(with event: NSEvent) {
        // The incoming window/view owns its cursor. Do not reset it to arrow
        // from a late exit event belonging to this image or another pin.
        onHoverChanged?()
    }

    @discardableResult
    func refreshCursorForCurrentLocation() -> Bool {
        guard window?.isVisible == true else { return false }
        let context = cursorContext()
        return refreshCursor(atScreenPoint: context.point, frontmostWindowNumber: context.frontmostWindowNumber)
    }

    @discardableResult
    func refreshCursor(atScreenPoint point: CGPoint, frontmostWindowNumber: Int) -> Bool {
        guard let window, window.isVisible, !window.ignoresMouseEvents, !isHiddenOrHasHiddenAncestor else { return false }
        if let gesture = resizeGesture {
            applyPointerStyle(.resize(gesture.handle))
            return true
        }
        // A child toolbar or another application's window must keep its own
        // cursor, even if a queued event still targets the image underneath.
        guard frontmostWindowNumber == window.windowNumber else { return false }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard bounds.contains(local) else { return false }
        if let handle = PinnedImageLayout.resizeHandle(at: local, in: bounds) {
            applyPointerStyle(.resize(handle))
        } else {
            applyPointerStyle(.move)
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        resizeGesture = nil
        guard event.type == .leftMouseDown, let window, !window.ignoresMouseEvents else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = PinnedImageLayout.resizeHandle(at: point, in: bounds) {
            resizeGesture = (handle, window.frame, window.convertPoint(toScreen: event.locationInWindow))
            refreshCursorForCurrentLocation()
        } else {
            window.performDrag(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, !window.ignoresMouseEvents else { resizeGesture = nil; return }
        guard let gesture = resizeGesture else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = CGSize(width: point.x - gesture.start.x, height: point.y - gesture.start.y)
        window.setFrame(PinnedImageLayout.resizedFrame(gesture.frame, handle: gesture.handle, delta: delta), display: true)
        refreshCursorForCurrentLocation()
    }

    override func mouseUp(with event: NSEvent) {
        resizeGesture = nil
        onHoverChanged?()
        refreshCursorForCurrentLocation()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        resizeGesture = nil
        if let panel = window as? PinnedImagePanel, panel.imageCursorOwner === self {
            panel.refreshImageCursor = nil
            panel.imageCursorOwner = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let panel = window as? PinnedImagePanel {
            panel.imageCursorOwner = self
            panel.refreshImageCursor = { [weak self] in self?.refreshCursorForCurrentLocation() }
        }
        updateTrackingAreas()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        refreshCursorForCurrentLocation()
    }
}

@MainActor
enum PinnedImageResizeCursor {
    static func cursor(for handle: SelectionHandle) -> NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch handle {
            case .topLeft: position = .topLeft
            case .top: position = .top
            case .topRight: position = .topRight
            case .right: position = .right
            case .bottomRight: position = .bottomRight
            case .bottom: position = .bottom
            case .bottomLeft: position = .bottomLeft
            case .left: position = .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch handle {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .bottomRight: return diagonalNWSE
        case .topRight, .bottomLeft: return diagonalNESW
        }
    }

    private static let diagonalNWSE = diagonalCursor(rising: false)
    private static let diagonalNESW = diagonalCursor(rising: true)

    /// High-contrast diagonal arrows for macOS 14, using only public drawing API.
    private static func diagonalCursor(rising: Bool) -> NSCursor {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            let a = NSPoint(x: 5, y: rising ? 5 : 19)
            let b = NSPoint(x: 19, y: rising ? 19 : 5)
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: a)
            path.line(to: b)
            for (tip, other) in [(a, b), (b, a)] {
                let dx: CGFloat = other.x > tip.x ? 6 : -6
                let dy: CGFloat = other.y > tip.y ? 6 : -6
                path.move(to: NSPoint(x: tip.x + dx, y: tip.y))
                path.line(to: tip)
                path.line(to: NSPoint(x: tip.x, y: tip.y + dy))
            }
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 2
            path.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }
}
