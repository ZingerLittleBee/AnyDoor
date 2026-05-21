import AppKit

/// Lightweight wrapper over NSSound for system feedback effects.
///
/// Uses macOS's own Finder sound files where possible so the UX matches
/// what users hear when interacting with Finder directly. Falls back to a
/// named system sound if the bundled asset has moved.
enum SystemSound {
    case emptyTrash

    /// Plays asynchronously. Safe to call from any actor; NSSound dispatches internally.
    func play() {
        guard let sound = makeSound() else { return }
        sound.play()
    }

    private func makeSound() -> NSSound? {
        switch self {
        case .emptyTrash:
            let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
            if FileManager.default.fileExists(atPath: path),
               let sound = NSSound(contentsOfFile: path, byReference: true) {
                return sound
            }
            return NSSound(named: NSSound.Name("Bottle"))
        }
    }
}
