import Foundation

enum ImageConversionPreferences {
    static let targetFormatKey = "imageConversion.targetFormat"
    static let qualityKey = "imageConversion.quality"

    /// Slider range and default, expressed as a whole percentage (1–100).
    static let minQualityPercent = 1
    static let maxQualityPercent = 100
    static let defaultQualityPercent = 85

    static func targetFormat(availableFormats: [ImageConversionFormat], defaults: UserDefaults = .standard) -> ImageConversionFormat {
        if let raw = defaults.string(forKey: targetFormatKey),
           let stored = ImageConversionFormat(rawValue: raw),
           availableFormats.contains(stored) {
            return stored
        }
        return availableFormats.first ?? .png
    }

    static func setTargetFormat(_ format: ImageConversionFormat, defaults: UserDefaults = .standard) {
        defaults.set(format.rawValue, forKey: targetFormatKey)
    }

    /// The persisted quality percentage, clamped to the valid range. A missing or
    /// out-of-range stored value falls back to the default so garbage can never
    /// reach the encoder.
    static func qualityPercent(defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: qualityKey) != nil else { return defaultQualityPercent }
        let stored = defaults.integer(forKey: qualityKey)
        guard stored >= minQualityPercent, stored <= maxQualityPercent else {
            return defaultQualityPercent
        }
        return stored
    }

    static func setQualityPercent(_ percent: Int, defaults: UserDefaults = .standard) {
        let clamped = min(max(percent, minQualityPercent), maxQualityPercent)
        defaults.set(clamped, forKey: qualityKey)
    }
}
