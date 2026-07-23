import AppKit
import PluginInterface
import PluginSupport
import SwiftUI

/// A floating, click-through countdown shown during a self-timer capture. It sits
/// horizontally centered in the lower portion of the target display and ticks a
/// large number down to 1; the caller dismisses it just before grabbing so it
/// never lands in the shot.
@MainActor
final class CaptureCountdownWindow {
    private var panel: NSPanel?
    private let model = CountdownModel()
    private var keyMonitorLocal: Any?
    private var keyMonitorGlobal: Any?

    /// Invoked when the user presses Esc to abort the countdown.
    var onCancel: (() -> Void)?

    fileprivate static let side: CGFloat = 140

    /// Shows the overlay seeded at `seconds`, horizontally centered and placed in
    /// the lower-middle of `screenFrame`. No-op for non-positive values.
    func present(seconds: Int, on screenFrame: CGRect) {
        guard seconds > 0 else { return }
        model.remaining = seconds

        let side = Self.side
        let origin = NSPoint(
            x: screenFrame.midX - side / 2,
            y: screenFrame.minY + screenFrame.height * 0.18
        )
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .screenSaver
        panel.hasShadow = false
        panel.ignoresMouseEvents = true   // never steal clicks while counting down
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let host = NSHostingView(rootView: CaptureCountdownView(model: model))
        host.frame = NSRect(origin: .zero, size: NSSize(width: side, height: side))
        panel.contentView = host
        panel.orderFrontRegardless()
        self.panel = panel

        // Esc aborts the countdown. A global monitor is required because the user
        // is typically arranging UI in another app while the timer runs (AnyDoor
        // is not key); the local monitor covers AnyDoor being frontmost. Both fire
        // on the main thread (see MainThreadIsolation).
        keyMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Esc */ else { return }
            MainThreadIsolation.run { self?.onCancel?() }
        }
        keyMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 /* Esc */ else { return event }
            MainThreadIsolation.run { self?.onCancel?() }
            return nil
        }
    }

    /// Updates the displayed number.
    func update(remaining: Int) { model.remaining = remaining }

    /// Removes the overlay from screen and tears down the key monitors.
    func dismiss() {
        if let m = keyMonitorLocal { NSEvent.removeMonitor(m); keyMonitorLocal = nil }
        if let m = keyMonitorGlobal { NSEvent.removeMonitor(m); keyMonitorGlobal = nil }
        panel?.orderOut(nil)
        panel = nil
    }
}

/// A click-through accent border drawn around the selection while a self-timer
/// counts down, so the user can see what region will be captured. Click-through
/// so transient UI can be arranged inside it, and removed before the grab so it
/// never lands in the shot.
@MainActor
final class CaptureRegionOutlineWindow {
    private var panel: NSPanel?

    /// Outlines `frame` (global AppKit coords, bottom-left origin).
    func present(frame: CGRect) {
        dismiss()
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = RegionOutlineView(frame: NSRect(origin: .zero, size: frame.size))
        p.orderFrontRegardless()
        panel = p
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class RegionOutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
    }
}

/// Observable seconds-remaining backing the countdown view.
@MainActor
private final class CountdownModel: ObservableObject {
    @Published var remaining: Int = 0
}

private struct CaptureCountdownView: View {
    @ObservedObject var model: CountdownModel

    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 72, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .frame(width: CaptureCountdownWindow.side, height: CaptureCountdownWindow.side)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}
