import AppKit
import SwiftUI

extension View {
    /// Hover tooltip rendered in a separate floating panel.
    ///
    /// SwiftUI's `.help(_:)` doesn't render in our hand-built panels, and an
    /// in-view bubble can't escape the window's bounds (so a control near an edge
    /// would be clipped). This shows the bubble in its own borderless, non-key
    /// panel positioned in screen space above the control — overflowing the host
    /// window freely, flipping below and clamping horizontally when the screen
    /// edge is in the way. Appears after a short hover delay.
    func hoverTooltip(_ text: String) -> some View {
        overlay(TooltipAnchor(text: text))
    }
}

/// A click-through overlay that tracks hover on the control beneath it and drives
/// the shared `TooltipPresenter` with the control's on-screen frame.
private struct TooltipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TooltipAnchorView {
        let view = TooltipAnchorView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: TooltipAnchorView, context: Context) {
        nsView.text = text
    }
}

final class TooltipAnchorView: NSView {
    var text: String = ""
    private var trackingArea: NSTrackingArea?
    private var showTask: Task<Void, Never>?

    // Tooltip display is driven by the tracking area, not hit-testing, so passing
    // every click through keeps the control beneath fully interactive.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        showTask?.cancel()
        showTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.present()
        }
    }

    override func mouseExited(with event: NSEvent) {
        showTask?.cancel()
        showTask = nil
        TooltipPresenter.shared.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The control left the hierarchy (panel closed / view rebuilt); drop any
        // pending or visible tooltip so it can't linger.
        if window == nil {
            showTask?.cancel()
            showTask = nil
            TooltipPresenter.shared.hide()
        }
    }

    private func present() {
        guard let window, !text.isEmpty else { return }
        let inWindow = convert(bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        TooltipPresenter.shared.show(text: text, anchorScreenRect: onScreen)
    }
}

/// One shared, reusable tooltip panel. Borderless, never key, ignores the mouse,
/// and sits above floating panels so it's visible over the translation panel.
@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private let panel: NSPanel
    private let hosting: NSHostingView<TooltipBubble>

    private init() {
        hosting = NSHostingView(rootView: TooltipBubble(text: ""))
        hosting.sizingOptions = [.intrinsicContentSize]

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the bubble draws its own shadow
        panel.level = .popUpMenu // above .floating panels
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
    }

    func show(text: String, anchorScreenRect: NSRect) {
        hosting.rootView = TooltipBubble(text: text)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        panel.setContentSize(size)

        let screen = NSScreen.screens.first { $0.frame.intersects(anchorScreenRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? anchorScreenRect

        // Centered above the anchor (screen y grows upward); flip below if the top
        // of the screen is in the way, and clamp within the visible frame.
        var x = anchorScreenRect.midX - size.width / 2
        var y = anchorScreenRect.maxY + 2
        if y + size.height > visible.maxY {
            y = anchorScreenRect.minY - size.height - 2
        }
        x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)

        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

private struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1))
            )
            .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
            // Inset so the bubble's shadow has room inside the panel and isn't clipped.
            .padding(8)
    }
}
