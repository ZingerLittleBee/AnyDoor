import Foundation

/// Output container for a finished recording.
enum RecordingFormat: String, Sendable, CaseIterable {
    case mov
    case mp4
    case gif

    var fileExtension: String { rawValue }

    /// Whether the format is produced by transcoding the captured `.mov`.
    var needsTranscode: Bool { self != .mov }
}

/// The recorder's lifecycle. `paused` keeps the session alive but stops writing.
enum RecordingState: Equatable, Sendable {
    case idle
    case recording
    case paused
    case finalizing
}

/// Pure recording helpers — no AVFoundation, no I/O. Unit tested.
enum RecordingPolicy {
    /// "M:SS" (or "H:MM:SS" past an hour) for an elapsed-seconds readout.
    static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Whether a control action is valid in the current state.
    static func canStart(_ state: RecordingState) -> Bool { state == .idle }
    static func canStop(_ state: RecordingState) -> Bool { state == .recording || state == .paused }
    static func canPause(_ state: RecordingState) -> Bool { state == .recording }
    static func canResume(_ state: RecordingState) -> Bool { state == .paused }

    /// Clamps a requested frame rate to a sane capture range.
    static func clampFrameRate(_ fps: Int) -> Int { min(60, max(10, fps)) }
}
