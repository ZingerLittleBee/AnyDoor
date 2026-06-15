import Foundation

/// Pure mapping from mode-bar affordances (digit keys, render order) to modes.
/// The bar renders region/window/fullscreen/timer; recording/scrolling are shown
/// disabled and are NOT produced here.
enum CaptureModeBarPolicy {
    static let orderedModes: [CaptureMode] = [.region, .window, .fullscreen]

    /// Digit 1/2/3 select the ordered modes; 4 is reserved for timer.
    static func mode(forDigit digit: Int) -> CaptureMode? {
        let index = digit - 1
        guard orderedModes.indices.contains(index) else { return nil }
        return orderedModes[index]
    }

    static func isTimerDigit(_ digit: Int) -> Bool { digit == 4 }
}
