import Foundation

/// The shared lossy-encode quality setting (a whole percentage, 1–100).
///
/// Two surfaces read it: the Image Conversion plugin's quality slider owns
/// the value, and Core's screenshot "Save As" transcode applies it to lossy
/// targets. It lives here — not in the plugin — because Save As is a Core
/// feature that must behave identically whether or not the plugin is
/// installed; the persisted value survives a logical uninstall like every
/// other plugin preference.
public enum ImageEncodingQuality {
    public static let key = "imageConversion.quality"

    /// Slider range and default.
    public static let minPercent = 1
    public static let maxPercent = 100
    public static let defaultPercent = 85

    /// The persisted quality percentage, clamped to the valid range. A missing
    /// or out-of-range stored value falls back to the default so garbage can
    /// never reach the encoder.
    public static func percent(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: key) != nil else { return defaultPercent }
        let stored = defaults.integer(forKey: key)
        guard stored >= minPercent, stored <= maxPercent else {
            return defaultPercent
        }
        return stored
    }

    public static func setPercent(_ percent: Int, defaults: UserDefaults = .standard) {
        let clamped = min(max(percent, minPercent), maxPercent)
        defaults.set(clamped, forKey: key)
    }
}
