import AVFoundation
import AppKit

/// Orchestrates a screen recording: permissions -> (region selection) -> engine
/// start -> on-screen overlays + controls -> stop -> export -> save. `@MainActor`,
/// callback-based (no cross-isolation await), mirroring `CaptureCoordinator`.
@MainActor
final class RecordingCoordinator {
    static let shared = RecordingCoordinator()

    private let engine = ScreenRecordingEngine()
    private let selectionOverlay = SelectionOverlayWindow()
    private(set) var state: RecordingState = .idle
    private var elapsedSeconds = 0
    private var timerTask: Task<Void, Never>?

    private var settings: RecordingSettings { .shared }

    private init() {
        engine.onFinish = { [weak self] url, error in self?.handleFinish(url: url, error: error) }
    }

    /// Hotkey / builtin entry point: start a fullscreen recording, or stop one.
    func toggle() {
        switch state {
        case .idle: record(region: false)
        case .recording, .paused: stop()
        case .finalizing: break
        }
    }

    /// Mode-bar entry point: record a selected region or the full display.
    func record(region: Bool) {
        guard state == .idle else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        ensureMediaPermissions(mic: settings.includeMicrophone, camera: settings.includeCamera) { [weak self] in
            guard let self else { return }
            if region { self.beginRegionSelection() }
            else if let target = Self.displayUnderMouse() {
                self.beginRecording(displayID: target.id, cropRect: nil)
            } else {
                self.finishIdle()
            }
        }
    }

    /// Record a pre-selected region (global AppKit coords) — used by the unified
    /// capture toolbar. Gates the same permissions as `record(region:)`, then starts
    /// recording without presenting its own selection.
    func record(rect: CGRect) {
        guard state == .idle else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        ensureMediaPermissions(mic: settings.includeMicrophone, camera: settings.includeCamera) { [weak self] in
            self?.beginRecording(globalRect: rect)
        }
    }

    func stop() {
        guard RecordingPolicy.canStop(state) else { return }
        state = .finalizing
        stopTimer()
        CameraOverlayWindow.shared.hide()
        KeystrokeOverlayWindow.shared.hide()
        RecordingControlsWindow.shared.dismiss()
        engine.stop()
    }

    func pause() {
        guard RecordingPolicy.canPause(state) else { return }
        engine.pause()
        state = .paused
        stopTimer()
    }

    func resume() {
        guard RecordingPolicy.canResume(state) else { return }
        engine.resume()
        state = .recording
        startTimer()
    }

    // MARK: - Region selection

    private func beginRegionSelection() {
        var frozen: [CGDirectDisplayID: CGImage] = [:]
        var targets: [TargetDisplay] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let img = LegacyScreenCapture.display(id) else { continue }
            targets.append(TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor))
            frozen[id] = img
        }
        guard !targets.isEmpty else { finishIdle(); return }
        selectionOverlay.present(targets: targets, mode: .region, frozen: frozen) { [weak self] result in
            guard let self else { return }
            guard case let .region(_, rect) = result else { self.finishIdle(); return }
            self.beginRecording(globalRect: rect)
        }
    }

    /// Map a global AppKit rect to its display + `AVCaptureScreenInput.cropRect`
    /// (the display's coordinate space, lower-left origin, points) and begin.
    private func beginRecording(globalRect rect: CGRect) {
        guard let screen = NSScreen.screens.first(where: {
                  $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
              }) ?? NSScreen.main,
              let id = screen.displayID else { finishIdle(); return }
        let crop = CGRect(x: rect.minX - screen.frame.minX, y: rect.minY - screen.frame.minY,
                          width: rect.width, height: rect.height)
        beginRecording(displayID: id, cropRect: crop)
    }

    // MARK: - Recording lifecycle

    private func beginRecording(displayID: CGDirectDisplayID, cropRect: CGRect?) {
        let url = recordingOutputURL()
        let config = ScreenRecordingEngine.Config(
            displayID: displayID,
            cropRect: cropRect,
            frameRate: settings.frameRate,
            showCursor: settings.showCursor,
            includeMicrophone: settings.includeMicrophone,
            outputURL: url
        )
        do {
            try engine.start(config)
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            finishIdle()
            return
        }
        state = .recording
        elapsedSeconds = 0
        startTimer()
        if settings.includeCamera { CameraOverlayWindow.shared.show() }
        if settings.showKeystrokes { KeystrokeOverlayWindow.shared.show() }
        RecordingControlsWindow.shared.present(
            onStop: { [weak self] in self?.stop() },
            onPauseToggle: { [weak self] in self?.togglePause() }
        )
    }

    private func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
        RecordingControlsWindow.shared.setPaused(state == .paused)
    }

    private func handleFinish(url: URL?, error: Error?) {
        guard let movURL = url else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            state = .idle
            return
        }
        let format = settings.format
        RecordingExporter.finalize(mov: movURL, to: format) { [weak self] finalURL in
            self?.state = .idle
            guard let finalURL else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                return
            }
            ToastPresenter.shared.show(.success(L(.recordingToastSaved, finalURL.deletingLastPathComponent().lastPathComponent)))
            NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        }
    }

    private func finishIdle() { state = .idle }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { break }
                self.elapsedSeconds += 1
                RecordingControlsWindow.shared.updateElapsed(self.elapsedSeconds)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - Helpers

    private func recordingOutputURL() -> URL {
        let dir = CaptureSettings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = CaptureFilename.make(template: RecordingSettings.defaultNamingTemplate, date: Date(), calendar: .current)
        let name = CaptureFilename.resolve(base: base, ext: "mov") {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        return dir.appendingPathComponent(name)
    }

    private static func displayUnderMouse() -> TargetDisplay? {
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        guard let screen, let id = screen.displayID else { return nil }
        return TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor)
    }

    private func ensureMediaPermissions(mic: Bool, camera: Bool, completion: @escaping @MainActor () -> Void) {
        // Request the (independent) mic/camera permissions in sequence, then hop
        // back to the main actor for `completion`. Using async/await avoids the
        // @Sendable capture dance the nested-callback form required under strict
        // concurrency, and matches the original "ask, then finish on main" flow.
        Task {
            if mic, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if camera, AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            await MainActor.run { completion() }
        }
    }
}
