import AppKit

extension NSColor {
    /// The color as an uppercase `"#RRGGBB"` string in the sRGB color space.
    ///
    /// Returns `nil` when the color cannot be converted to sRGB (e.g. pattern
    /// colors). Each component is clamped to `0...1` before scaling — sampling
    /// on wide-gamut displays can yield components slightly outside that range.
    var sRGBHexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }
}
