import AppKit
import SwiftUI

/// All-In-One floating mode bar. Shows region/window/fullscreen/timer/recording/
/// scrolling (all enabled). Selecting a mode dismisses the bar and calls back.
/// Digit keys 1–4 and Esc are handled via a local key monitor.
@MainActor
final class CaptureModeBarWindow {
    static let shared = CaptureModeBarWindow()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var onPick: ((CaptureMode) -> Void)?
    private var onTimer: (() -> Void)?
    private var onRecord: (() -> Void)?
    private var onScroll: (() -> Void)?

    private init() {}

    func present(
        onPick: @escaping (CaptureMode) -> Void,
        onTimer: @escaping () -> Void,
        onRecord: @escaping () -> Void,
        onScroll: @escaping () -> Void
    ) {
        close()
        self.onPick = onPick
        self.onTimer = onTimer
        self.onRecord = onRecord
        self.onScroll = onScroll

        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = CGSize(width: 460, height: 92)
        let origin = CGPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - 80
        )

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        // `.canJoinAllSpaces` and `.moveToActiveSpace` are mutually exclusive; both
        // together make macOS 26's `_validateCollectionBehavior` throw. Keep one.
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: CaptureModeBarView(
            onRegion: { [weak self] in self?.pick(.region) },
            onWindow: { [weak self] in self?.pick(.window) },
            onFullscreen: { [weak self] in self?.pick(.fullscreen) },
            onTimer: { [weak self] in self?.timer() },
            onRecord: { [weak self] in self?.record() },
            onScroll: { [weak self] in self?.scroll() }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()

        // Local key monitor: Esc closes, digits 1–4 trigger modes/timer.
        // The closure is non-isolated and runs on the main thread; run the
        // MainActor-isolated side effect synchronously via MainThreadIsolation
        // rather than MainActor.assumeIsolated: asserting the current executor
        // from an event-monitor callback can fault inside the concurrency runtime
        // after a ScreenCaptureKit capture (see MainThreadIsolation).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                MainThreadIsolation.run { self.close() }
                return nil
            }
            if let digit = Int(event.charactersIgnoringModifiers ?? "") {
                if CaptureModeBarPolicy.isTimerDigit(digit) {
                    MainThreadIsolation.run { self.timer() }
                    return nil
                }
                if let mode = CaptureModeBarPolicy.mode(forDigit: digit) {
                    MainThreadIsolation.run { self.pick(mode) }
                    return nil
                }
            }
            return event
        }
    }

    private func pick(_ mode: CaptureMode) {
        let cb = onPick
        close()
        cb?(mode)
    }

    private func timer() {
        let cb = onTimer
        close()
        cb?()
    }

    private func record() {
        let cb = onRecord
        close()
        cb?()
    }

    private func scroll() {
        let cb = onScroll
        close()
        cb?()
    }

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        onPick = nil
        onTimer = nil
        onRecord = nil
        onScroll = nil
    }
}

// MARK: - Bar view

private struct CaptureModeBarView: View {
    let onRegion: () -> Void
    let onWindow: () -> Void
    let onFullscreen: () -> Void
    let onTimer: () -> Void
    let onRecord: () -> Void
    let onScroll: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            modeItem("rectangle.dashed", L(.captureModeBarRegion), onRegion)
            modeItem("macwindow", L(.captureModeBarWindow), onWindow)
            modeItem("rectangle.inset.filled", L(.captureModeBarFullscreen), onFullscreen)
            modeItem("timer", L(.captureModeBarTimer), onTimer)
            Divider().frame(height: 40)
            modeItem("record.circle", L(.captureModeBarRecording), onRecord)
            modeItem("arrow.down.to.line", L(.captureModeBarScrolling), onScroll)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func modeItem(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
    }
}
