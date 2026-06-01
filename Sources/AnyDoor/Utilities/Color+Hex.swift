import SwiftUI

extension Color {
    /// Parses `"#RRGGBB"` (or `"RRGGBB"`) into an sRGB `Color`. Returns `nil` on
    /// malformed input so callers can fall back to a neutral swatch. This is the
    /// single hex→Color parser shared across the clipboard UI (card wall, history
    /// row swatch, and the history popover preview overlay).
    init?(hex: String?) {
        guard var raw = hex?.uppercased() else { return nil }
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = UInt32(raw, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0,
            opacity: 1
        )
    }
}
