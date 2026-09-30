import AppKit
import PluginInterface
import PluginSupport
import SwiftUI

/// An always-on-top floating image for reference. Drag to move, resize from its
/// edges, adjust opacity, or toggle click-through. Each pin is its own window.
@MainActor
final class PinnedImageWindow {
    private static var windows: [PinnedImageWindow] = []

    private var panel: NSPanel?
    private var clickThrough = false
    // While click-through is enabled the panel ignores mouse events, so the hover
    // controls can never reappear; an Escape monitor lets the user disable it.
    nonisolated(unsafe) private var escapeMonitorLocal: Any?
    nonisolated(unsafe) private var escapeMonitorGlobal: Any?

    static func show(image: NSImage, at screenFrame: CGRect) {
        let win = PinnedImageWindow()
        win.present(image: image, at: screenFrame)
        windows.append(win)
    }

    private func present(image: NSImage, at screenFrame: CGRect) {
        let size = PinnedImageLayout.initialSize(for: image.size)
        let origin = CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )

        let p = Self.makePanel(frame: CGRect(origin: origin, size: size))

        let hosting = NSHostingView(rootView: PinnedImageView(
            image: image,
            onClose: { [weak self] in self?.close() },
            onOpacity: { [weak self] value in self?.panel?.alphaValue = value },
            onToggleClickThrough: { [weak self] in self?.toggleClickThrough() }
        ).environment(LocalizationManager.shared))
        // The user owns the window size. Image dimensions and hover controls
        // must not feed their intrinsic size back into the panel's constraints.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()
    }

    /// Let AppKit own edge/corner resizing and its native resize cursors.
    /// Image.resizable() only scales content; it cannot resize an NSPanel.
    static func makePanel(frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        // Image-body drags are explicit; slider/button events stay in SwiftUI.
        panel.isMovableByWindowBackground = false
        panel.contentMinSize = PinnedImageLayout.minimumSize
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return panel
    }

    private func toggleClickThrough() {
        clickThrough.toggle()
        panel?.ignoresMouseEvents = clickThrough
        if clickThrough {
            installEscapeMonitors()
        } else {
            removeEscapeMonitors()
        }
    }

    /// While click-through is on, Escape disables it so interactivity and the
    /// hover controls (toggle/close) come back — otherwise the pin is a dead end.
    private func installEscapeMonitors() {
        guard escapeMonitorLocal == nil, escapeMonitorGlobal == nil else { return }
        // Run the MainActor-isolated side effect synchronously via
        // MainThreadIsolation rather than MainActor.assumeIsolated: asserting the
        // current executor from an event-monitor callback can fault inside the
        // concurrency runtime after a ScreenCaptureKit capture (see
        // MainThreadIsolation).
        escapeMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Esc */ else { return event }
            MainThreadIsolation.run { self?.disableClickThrough() }
            return nil
        }
        // Global monitors can't consume the event; observing Escape is enough.
        escapeMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Esc */ else { return }
            MainThreadIsolation.run { self?.disableClickThrough() }
        }
    }

    private func removeEscapeMonitors() {
        if let m = escapeMonitorLocal { NSEvent.removeMonitor(m); escapeMonitorLocal = nil }
        if let m = escapeMonitorGlobal { NSEvent.removeMonitor(m); escapeMonitorGlobal = nil }
    }

    private func disableClickThrough() {
        clickThrough = false
        panel?.ignoresMouseEvents = false
        removeEscapeMonitors()
    }

    private func close() {
        removeEscapeMonitors()
        panel?.orderOut(nil)
        panel = nil
        PinnedImageWindow.windows.removeAll { $0 === self }
    }
}

/// A native mouse target independent of SwiftUI's image hit-testing. Keeping it
/// below the controls lets them receive their own clicks and slider drags.
private struct PinnedImageDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedImageDragView { PinnedImageDragView() }
    func updateNSView(_ nsView: PinnedImageDragView, context: Context) {}
}

@MainActor
final class PinnedImageDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        // Leave the perimeter to AppKit and the top strip to the controls, so
        // the grab cursor cannot hide native resize/slider/button feedback.
        var body = bounds.insetBy(dx: 8, dy: 8)
        body.size.height = max(0, body.height - 48)
        if !body.isEmpty { addCursorRect(body, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, !window.ignoresMouseEvents else { return }
        // Hand the original event to the Window Server, including cross-display
        // movement and Spaces behavior. Do not move the frame in a SwiftUI gesture.
        window.performDrag(with: event)
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    let onOpacity: (CGFloat) -> Void
    let onToggleClickThrough: () -> Void

    @State private var opacity: Double = 1
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            PinnedImageDragSurface()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .help(L(.capturePinnedMoveResize))
            if hovering {
                HStack(spacing: 8) {
                    Slider(value: $opacity, in: 0.2...1).frame(width: 80)
                        .onChange(of: opacity) { _, v in onOpacity(CGFloat(v)) }
                        .help(L(.capturePinnedOpacity))
                    Button(action: onToggleClickThrough) {
                        Image(systemName: "cursorarrow.slash")
                    }
                    .buttonStyle(.plain)
                    .help(L(.capturePinnedClickThrough))
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help(L(.clipboardPreviewClose))
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.12))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(hovering ? 0.6 : 0.2), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHoverSafe { hovering = $0 }
        .focusEffectDisabled()
    }
}
