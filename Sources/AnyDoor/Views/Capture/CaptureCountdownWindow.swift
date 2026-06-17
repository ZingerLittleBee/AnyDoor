import AppKit
import SwiftUI

/// A floating, click-through countdown shown during a self-timer capture. It sits
/// at the center of the display under the cursor and ticks a large number down to
/// 1; the caller dismisses it just before grabbing so it never lands in the shot.
@MainActor
final class CaptureCountdownWindow {
    private var panel: NSPanel?
    private let model = CountdownModel()

    fileprivate static let side: CGFloat = 140

    /// Shows the overlay seeded at `seconds`. No-op for non-positive values.
    func present(seconds: Int) {
        guard seconds > 0 else { return }
        model.remaining = seconds

        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        let side = Self.side
        let panel = NSPanel(
            contentRect: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side),
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
    }

    /// Updates the displayed number.
    func update(remaining: Int) { model.remaining = remaining }

    /// Removes the overlay from screen.
    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
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
