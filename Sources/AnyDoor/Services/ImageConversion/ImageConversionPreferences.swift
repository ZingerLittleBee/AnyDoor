import Foundation

enum ImageConversionPreferences {
    private static let targetFormatKey = "imageConversion.targetFormat"

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
}
