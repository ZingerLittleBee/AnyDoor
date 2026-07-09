import AppKit

/// Lightweight wrapper over NSSound for system feedback effects.
///
/// Uses macOS's own sound files where possible so the UX matches what users hear
/// when the system performs the same action directly. Falls back through a chain
/// of equivalent assets if a bundled file has moved.
enum SystemSound {
    case emptyTrash
    /// The shutter sound macOS plays for native screenshots (⌘⇧3/4/5).
    case screenCapture
    /// Completion chime for an explicit user-initiated save (e.g. Save As).
    case saveSuccess

    /// Plays asynchronously. Safe to call from any actor; NSSound dispatches internally.
    func play() {
        guard let sound = makeSound() else { return }
        sound.play()
    }

    private func makeSound() -> NSSound? {
        switch self {
        case .emptyTrash:
            return Self.firstExistingSound(
                paths: ["\(Self.finderDir)/empty trash.aif"]
            ) ?? NSSound(named: NSSound.Name("Bottle"))
        case .screenCapture:
            // Prefer the exact native screenshot sound; fall back to the classic
            // Grab / generic camera shutter shipped alongside it.
            return Self.firstExistingSound(paths: [
                "\(Self.systemDir)/Screen Capture.aif",
                "\(Self.systemDir)/Shutter.aif",
                "\(Self.systemDir)/Grab.aif",
            ])
        case .saveSuccess:
            // The classic Glass alert reads as "operation finished"; it ships in
            // /System/Library/Sounds on every supported macOS.
            return NSSound(named: NSSound.Name("Glass"))
        }
    }

    private static let soundsRoot =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"
    private static let systemDir = "\(soundsRoot)/system"
    private static let finderDir = "\(soundsRoot)/finder"

    /// Returns the first readable sound from `paths`, or nil if none exist.
    private static func firstExistingSound(paths: [String]) -> NSSound? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
        }
        return nil
    }
}
