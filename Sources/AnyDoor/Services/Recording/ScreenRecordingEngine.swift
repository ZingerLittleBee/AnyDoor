import AVFoundation
import AppKit

/// AVFoundation screen-recording engine. Uses `AVCaptureScreenInput` (not
/// ScreenCaptureKit) so it never triggers the macOS 26 executor-corruption crash
/// that SCK's async capture caused (see `LegacyScreenCapture`). Records the chosen
/// display (optionally cropped, optionally with the microphone) to a `.mov`, then
/// reports the URL via `onFinish`.
@MainActor
final class ScreenRecordingEngine: NSObject {
    /// Configuration for a single recording.
    struct Config {
        var displayID: CGDirectDisplayID
        /// Crop in the display's coordinate space (points, bottom-left origin); nil
        /// records the whole display.
        var cropRect: CGRect?
        var frameRate: Int
        var showCursor: Bool
        var includeMicrophone: Bool
        var outputURL: URL
    }

    private let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private(set) var isRunning = false

    /// Called once when recording finishes (or fails). `url` is the written `.mov`.
    var onFinish: ((URL?, Error?) -> Void)?

    enum RecordingError: Error { case screenInputUnavailable }

    func start(_ config: Config) throws {
        guard !isRunning else { return }
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let screen = AVCaptureScreenInput(displayID: config.displayID) else {
            session.commitConfiguration()
            throw RecordingError.screenInputUnavailable
        }
        screen.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(RecordingPolicy.clampFrameRate(config.frameRate)))
        screen.capturesCursor = config.showCursor
        screen.capturesMouseClicks = true
        if let crop = config.cropRect, crop.width >= 1, crop.height >= 1 {
            screen.cropRect = crop
        }
        if session.canAddInput(screen) { session.addInput(screen) }

        if config.includeMicrophone,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        session.commitConfiguration()

        session.startRunning()
        movieOutput.startRecording(to: config.outputURL, recordingDelegate: self)
        isRunning = true
    }

    /// Stops recording; `onFinish` fires from the delegate when the file is closed.
    func stop() {
        guard isRunning else { return }
        movieOutput.stopRecording()
    }

    func pause() { movieOutput.pauseRecording() }
    func resume() { movieOutput.resumeRecording() }

    private func teardown() {
        if session.isRunning { session.stopRunning() }
        for input in session.inputs { session.removeInput(input) }
        if session.outputs.contains(movieOutput) { session.removeOutput(movieOutput) }
        isRunning = false
    }
}

extension ScreenRecordingEngine: AVCaptureFileOutputRecordingDelegate {
    // Called by AVFoundation off the main thread — hop back explicitly.
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.teardown()
            // A user-initiated stop surfaces as an AVError the file is still valid;
            // only treat a missing file as a real failure.
            let fileExists = FileManager.default.fileExists(atPath: outputFileURL.path)
            self.onFinish?(fileExists ? outputFileURL : nil, fileExists ? nil : error)
        }
    }
}
