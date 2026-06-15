import Foundation

/// Formats a key event into a display string (e.g. "⇧⌘A") for the recording
/// keystroke overlay. Pure — modifier symbols in canonical macOS order followed by
/// the key name from `KeyCodeMap`.
enum KeystrokeFormatter {
    static func display(keyCode: Int, control: Bool, option: Bool, shift: Bool, command: Bool) -> String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += KeyCodeMap.name(for: keyCode)
        return s
    }
}
