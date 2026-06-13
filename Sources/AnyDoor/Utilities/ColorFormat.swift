import Foundation

/// Output representations for a picked color. `format(hex:)` is a pure function
/// over a `"#RRGGBB"` string (the value `ColorSampler` returns), so it is fully
/// unit-testable without the system color loupe.
enum ColorFormat: String, CaseIterable, Sendable {
    case hex
    case rgb
    case hsl
    case swiftUI
    case css

    /// UserDefaults key holding the user's preferred output format. Portable via
    /// `SyncSettingsRegistry`.
    static let defaultsKey = "pickColor.format"

    /// The currently selected default format (used by every pick path), falling
    /// back to `.hex` when unset or unrecognized.
    static var current: ColorFormat {
        get { ColorFormat(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .hex }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// Render a `"#RRGGBB"` string in this format. Returns nil when `hex` is not a
    /// valid 6-digit hex color.
    func format(hex: String) -> String? {
        guard let (r, g, b) = Self.components(from: hex) else { return nil }
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", r, g, b)
        case .css:
            return String(format: "#%02x%02x%02x", r, g, b)
        case .rgb:
            return "rgb(\(r), \(g), \(b))"
        case .swiftUI:
            return String(
                format: "Color(red: %.3f, green: %.3f, blue: %.3f)",
                Double(r) / 255, Double(g) / 255, Double(b) / 255
            )
        case .hsl:
            let (h, s, l) = Self.hsl(r: r, g: g, b: b)
            return "hsl(\(h), \(s)%, \(l)%)"
        }
    }

    /// Parse `"#RRGGBB"` into 0...255 channels. Case-insensitive; requires the
    /// leading `#` and exactly six hex digits.
    private static func components(from hex: String) -> (Int, Int, Int)? {
        guard hex.hasPrefix("#") else { return nil }
        let digits = hex.dropFirst()
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return nil }
        return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
    }

    /// Standard HSL conversion, rounded to integer degrees / percents.
    private static func hsl(r: Int, g: Int, b: Int) -> (Int, Int, Int) {
        let rf = Double(r) / 255, gf = Double(g) / 255, bf = Double(b) / 255
        let maxV = max(rf, gf, bf), minV = min(rf, gf, bf)
        let delta = maxV - minV
        let l = (maxV + minV) / 2

        guard delta != 0 else { return (0, 0, Int((l * 100).rounded())) }

        let s = delta / (1 - abs(2 * l - 1))
        var h: Double
        if maxV == rf {
            h = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == gf {
            h = (bf - rf) / delta + 2
        } else {
            h = (rf - gf) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (Int(h.rounded()), Int((s * 100).rounded()), Int((l * 100).rounded()))
    }
}
