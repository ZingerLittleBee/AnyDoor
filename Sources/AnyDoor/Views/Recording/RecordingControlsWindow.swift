import AppKit
import SwiftUI

/// Small floating control bar shown while recording: a pulsing record dot, the
/// elapsed time, pause/resume, and stop. Note: for a fullscreen recording on a
/// single display this bar is captured in the video; record a region (or use a
/// second display) to keep it out of frame.
@MainActor
final class RecordingControlsWindow {
    static let shared = RecordingControlsWindow()
    private var panel: NSPanel?
    private let model = RecordingControlsModel()

    private init() {}

    func present(onStop: @escaping () -> Void, onPauseToggle: @escaping () -> Void) {
        model.elapsed = 0
        model.isPaused = false
        model.onStop = onStop
        model.onPauseToggle = onPauseToggle
        guard panel == nil else { return }

        let size = CGSize(width: 220, height: 48)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = CGPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12)
        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: RecordingControlsView(model: model))
        p.orderFrontRegardless()
        panel = p
    }

    func updateElapsed(_ seconds: Int) { model.elapsed = seconds }
    func setPaused(_ paused: Bool) { model.isPaused = paused }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
@Observable
final class RecordingControlsModel {
    var elapsed: Int = 0
    var isPaused: Bool = false
    var onStop: (() -> Void)?
    var onPauseToggle: (() -> Void)?
}

private struct RecordingControlsView: View {
    @Bindable var model: RecordingControlsModel

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(model.isPaused ? Color.gray : Color.red)
                .frame(width: 10, height: 10)
            Text(RecordingPolicy.formatElapsed(model.elapsed))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            Button { model.onPauseToggle?() } label: {
                Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            Button { model.onStop?() } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
        .padding(.horizontal, 14)
        .frame(width: 220, height: 48)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
