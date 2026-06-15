import AppKit

/// A click-through, transparent border drawn around the scrolling-capture
/// viewport so the user knows where to scroll. Ordered above the preview panel so
/// the session's below-preview grab excludes it from the stitched image.
@MainActor
final class ScrollViewportOutlineWindow {
    private var panel: NSPanel?

    func present(frame: CGRect) {
        dismiss()
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
        p.orderFrontRegardless()
        panel = p
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
    }
}
