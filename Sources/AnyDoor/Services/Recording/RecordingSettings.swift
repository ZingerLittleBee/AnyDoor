import Foundation

/// UserDefaults-backed screen-recording configuration. Mirrors `CaptureSettings`
/// (explicit write-through setters, `@Observable` for SwiftUI). Recordings are
/// saved alongside screenshots in `CaptureSettings.saveDirectory`.
@MainActor
@Observable
final class RecordingSettings {
    static let shared = RecordingSettings()

    static let frameRateKey = "recording.frameRate"
    static let showCursorKey = "recording.showCursor"
    static let includeMicrophoneKey = "recording.includeMicrophone"
    static let includeCameraKey = "recording.includeCamera"
    static let showKeystrokesKey = "recording.showKeystrokes"
    static let formatKey = "recording.format"

    static let defaultNamingTemplate = "Recording YYYY-MM-DD at HH.mm.ss"

    private let defaults: UserDefaults

    private(set) var frameRate: Int
    private(set) var showCursor: Bool
    private(set) var includeMicrophone: Bool
    private(set) var includeCamera: Bool
    private(set) var showKeystrokes: Bool
    private(set) var format: RecordingFormat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.frameRate = RecordingPolicy.clampFrameRate(defaults.object(forKey: Self.frameRateKey) as? Int ?? 30)
        self.showCursor = defaults.object(forKey: Self.showCursorKey) as? Bool ?? true
        self.includeMicrophone = defaults.object(forKey: Self.includeMicrophoneKey) as? Bool ?? false
        self.includeCamera = defaults.object(forKey: Self.includeCameraKey) as? Bool ?? false
        self.showKeystrokes = defaults.object(forKey: Self.showKeystrokesKey) as? Bool ?? false
        self.format = RecordingFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .mp4
    }

    func setFrameRate(_ value: Int) {
        frameRate = RecordingPolicy.clampFrameRate(value)
        defaults.set(frameRate, forKey: Self.frameRateKey)
    }
    func setShowCursor(_ value: Bool) { showCursor = value; defaults.set(value, forKey: Self.showCursorKey) }
    func setIncludeMicrophone(_ value: Bool) { includeMicrophone = value; defaults.set(value, forKey: Self.includeMicrophoneKey) }
    func setIncludeCamera(_ value: Bool) { includeCamera = value; defaults.set(value, forKey: Self.includeCameraKey) }
    func setShowKeystrokes(_ value: Bool) { showKeystrokes = value; defaults.set(value, forKey: Self.showKeystrokesKey) }
    func setFormat(_ value: RecordingFormat) { format = value; defaults.set(value.rawValue, forKey: Self.formatKey) }

    func reloadFromDefaults() {
        frameRate = RecordingPolicy.clampFrameRate(defaults.object(forKey: Self.frameRateKey) as? Int ?? 30)
        showCursor = defaults.object(forKey: Self.showCursorKey) as? Bool ?? true
        includeMicrophone = defaults.object(forKey: Self.includeMicrophoneKey) as? Bool ?? false
        includeCamera = defaults.object(forKey: Self.includeCameraKey) as? Bool ?? false
        showKeystrokes = defaults.object(forKey: Self.showKeystrokesKey) as? Bool ?? false
        format = RecordingFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .mp4
    }
}
