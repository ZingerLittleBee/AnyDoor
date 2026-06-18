import Foundation

/// A connected Bluetooth accessory together with whatever battery readings macOS
/// exposes for it. True-wireless earbuds populate `left` / `right` / `caseLevel`;
/// every other device reports a single `main` level. All percentages are 0–100,
/// or `nil` when that slot is unknown.
struct BluetoothBatteryDevice: Identifiable, Hashable, Sendable {
    /// Stable identity: the normalized device address when known, otherwise the
    /// lowercased name (pmset-only devices have no address).
    let id: String
    let name: String
    /// Raw `device_minorType` from system_profiler (e.g. "Keyboard", "Mouse",
    /// "Headphones"); `nil` for pmset-only devices whose type we never learned.
    let minorType: String?
    let main: Int?
    let left: Int?
    let right: Int?
    let caseLevel: Int?

    /// True when the device reports the left/right/case triple (earbuds).
    var isEarbuds: Bool { left != nil || right != nil || caseLevel != nil }

    /// All known readings, used for sorting and low-battery checks.
    var levels: [Int] { [main, left, right, caseLevel].compactMap { $0 } }

    /// The lowest reading across every populated slot, or `nil` if none.
    var lowestLevel: Int? { levels.min() }

    /// SF Symbol representing the device category. Falls back to a generic
    /// Bluetooth glyph when the type is unknown or unrecognized.
    var symbol: String {
        switch minorType?.lowercased() {
        case let t? where t.contains("keyboard"): return "keyboard"
        case let t? where t.contains("trackpad"): return "rectangle.and.hand.point.up.left"
        case let t? where t.contains("mouse"):     return "computermouse"
        case let t? where t.contains("headphone"): return "airpods"
        case let t? where t.contains("headset"):   return "headphones"
        case let t? where t.contains("speaker"):   return "hifispeaker"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

extension Int {
    /// Maps a 0–100 battery percentage to the closest `battery.NN` SF Symbol.
    var batterySymbolName: String {
        switch self {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default:    return "battery.0"
        }
    }
}
