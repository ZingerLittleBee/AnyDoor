import AppKit
import SwiftUI

struct PinnedImageInteractionSurface: NSViewRepresentable {
    let onHoverChanged: @MainActor () -> Void

    func makeNSView(context: Context) -> PinnedImageDragView {
        let view = PinnedImageDragView()
        view.onHoverChanged = onHoverChanged
        view.toolTip = L(.capturePinnedMoveResize)
        return view
    }

    func updateNSView(_ nsView: PinnedImageDragView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.toolTip = L(.capturePinnedMoveResize)
    }
}

/// Owns inside-edge resizing instead of relying on borderless native resizing.
/// Original screen coordinates prevent frame feedback from compounding a drag.
@MainActor
final class PinnedImageDragView: NSView {
    var onHoverChanged: (@MainActor () -> Void)?
    private var resizeGesture: (handle: SelectionHandle, frame: CGRect, start: CGPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: PinnedImageLayout.resizeBorderWidth, dy: PinnedImageLayout.resizeBorderWidth), cursor: .openHand)
        for (handle, rect) in PinnedImageLayout.resizeRegions(in: bounds) {
            addCursorRect(rect, cursor: PinnedImageResizeCursor.cursor(for: handle))
        }
    }

    override func mouseEntered(with event: NSEvent) {
        updateCursor(with: event)
        onHoverChanged?()
    }

    override func mouseMoved(with event: NSEvent) { updateCursor(with: event) }

    override func mouseExited(with event: NSEvent) {
        if resizeGesture == nil { NSCursor.arrow.set() }
        onHoverChanged?()
    }

    private func updateCursor(with event: NSEvent) {
        guard window?.ignoresMouseEvents == false else { return }
        let point = convert(event.locationInWindow, from: nil)
        let handle = resizeGesture?.handle ?? PinnedImageLayout.resizeHandle(at: point, in: bounds)
        if let handle {
            PinnedImageResizeCursor.cursor(for: handle).set()
        } else if bounds.contains(point) {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        resizeGesture = nil
        guard event.type == .leftMouseDown, let window, !window.ignoresMouseEvents else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle = PinnedImageLayout.resizeHandle(at: point, in: bounds) {
            resizeGesture = (handle, window.frame, window.convertPoint(toScreen: event.locationInWindow))
            PinnedImageResizeCursor.cursor(for: handle).set()
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
        PinnedImageResizeCursor.cursor(for: gesture.handle).set()
    }

    override func mouseUp(with event: NSEvent) {
        resizeGesture = nil
        updateCursor(with: event)
        onHoverChanged?()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        resizeGesture = nil
        super.viewWillMove(toWindow: newWindow)
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
