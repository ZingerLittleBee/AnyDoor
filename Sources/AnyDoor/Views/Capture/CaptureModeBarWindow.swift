import AppKit
import SwiftUI

/// All-In-One floating mode bar. Shows region/window/fullscreen/timer (enabled)
/// and recording/scrolling (disabled placeholders). Selecting a mode dismisses
/// the bar and calls back. Digit keys 1–4 and Esc are handled via a local key
/// monitor.
@MainActor
final class CaptureModeBarWindow {
    static let shared = CaptureModeBarWindow()

    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var onPick: ((CaptureMode) -> Void)?
    private var onTimer: (() -> Void)?

    private init() {}

    func present(onPick: @escaping (CaptureMode) -> Void, onTimer: @escaping () -> Void) {
        close()
        self.onPick = onPick
        self.onTimer = onTimer

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
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]

        let hosting = NSHostingView(rootView: CaptureModeBarView(
            onRegion: { [weak self] in self?.pick(.region) },
            onWindow: { [weak self] in self?.pick(.window) },
            onFullscreen: { [weak self] in self?.pick(.fullscreen) },
            onTimer: { [weak self] in self?.timer() }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()

        // Local key monitor: Esc closes, digits 1–4 trigger modes/timer.
        // The closure is non-isolated; wrap body in MainActor.assumeIsolated so
        // we can safely access self's MainActor-isolated state — this mirrors the
        // pattern in ScreenshotPreviewWindow.swift.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                MainActor.assumeIsolated { self.close() }
                return nil
            }
            if let digit = Int(event.charactersIgnoringModifiers ?? "") {
                if CaptureModeBarPolicy.isTimerDigit(digit) {
                    MainActor.assumeIsolated { self.timer() }
                    return nil
                }
                if let mode = CaptureModeBarPolicy.mode(forDigit: digit) {
                    MainActor.assumeIsolated { self.pick(mode) }
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

    func close() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        onPick = nil
        onTimer = nil
    }
}

// MARK: - Bar view

private struct CaptureModeBarView: View {
    let onRegion: () -> Void
    let onWindow: () -> Void
    let onFullscreen: () -> Void
    let onTimer: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            modeItem("rectangle.dashed", L(.captureModeBarRegion), onRegion)
            modeItem("macwindow", L(.captureModeBarWindow), onWindow)
            modeItem("rectangle.inset.filled", L(.captureModeBarFullscreen), onFullscreen)
            modeItem("timer", L(.captureModeBarTimer), onTimer)
            Divider().frame(height: 40)
            disabledItem("record.circle", L(.captureModeBarRecording))
            disabledItem("arrow.down.to.line", L(.captureModeBarScrolling))
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

    private func disabledItem(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(title).font(.caption2)
        }
        .frame(width: 56)
        .foregroundStyle(.tertiary)
    }
}
