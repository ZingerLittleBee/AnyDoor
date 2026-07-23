import Foundation
import ImageCodec

/// Which conversion strategy the Image Conversion UI is currently driving. Stored
/// as a raw string so it stays portable and survives a lightweight schema change.
enum ImageConversionMode: String, CaseIterable, Sendable {
    case quality
    case targetSize
}

enum ImageConversionPreferences {
    static let targetFormatKey = "imageConversion.targetFormat"
    static let qualityKey = ImageEncodingQuality.key

    static let modeKey = "imageConversion.mode"
    static let targetSizeBytesKey = "imageConversion.targetSize.bytes"
    static let targetSizeUnitKey = "imageConversion.targetSize.unit"
    static let transparencyBackgroundHexKey = "imageConversion.transparencyBackgroundHex"
    static let outputDirectoryKey = "imageConversion.outputDirectory"

    static let defaultMode: ImageConversionMode = .quality
    static let defaultTargetSizeBytes = 1_000_000
    static let defaultTargetSizeUnit: TargetSizeUnit = .mb
    static let defaultTransparencyBackgroundHex = "#FFFFFF"

    /// Slider range and default, expressed as a whole percentage (1–100).
    /// Sourced from the shared codec setting so Core's screenshot Save As and
    /// the plugin's slider stay one knob.
    static let minQualityPercent = ImageEncodingQuality.minPercent
    static let maxQualityPercent = ImageEncodingQuality.maxPercent
    static let defaultQualityPercent = ImageEncodingQuality.defaultPercent

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

    /// The last output directory the user picked for a run. Machine-specific
    /// (a local filesystem path), so it is deliberately not in the sync
    /// registry. Returns nil when nothing was stored or the directory is gone.
    static func outputDirectory(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: outputDirectoryKey), !path.isEmpty else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func setOutputDirectory(_ url: URL, defaults: UserDefaults = .standard) {
        defaults.set(url.path, forKey: outputDirectoryKey)
    }

    /// The persisted quality percentage; see `ImageEncodingQuality.percent`.
    static func qualityPercent(defaults: UserDefaults = .standard) -> Int {
        ImageEncodingQuality.percent(defaults: defaults)
    }

    static func setQualityPercent(_ percent: Int, defaults: UserDefaults = .standard) {
        ImageEncodingQuality.setPercent(percent, defaults: defaults)
    }

    // MARK: - Target Size mode

    /// The active conversion mode. A missing or unrecognized raw string falls back
    /// to Quality so an imported garbage value can never leave the UI in an
    /// unknown state.
    static func mode(defaults: UserDefaults = .standard) -> ImageConversionMode {
        guard let raw = defaults.string(forKey: modeKey),
              let stored = ImageConversionMode(rawValue: raw) else {
            return defaultMode
        }
        return stored
    }

    static func setMode(_ mode: ImageConversionMode, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// The Per-Output Limit as an exact byte budget plus its presentation unit.
    /// The byte count and the unit fall back independently: a bad unit never
    /// resets a valid byte count and vice versa. Bytes outside `(0, maxBytes]`
    /// reset to the 1 MB default; an unknown unit resets to MB.
    static func targetSizeLimit(defaults: UserDefaults = .standard) -> TargetSizeLimit {
        let bytes: Int64
        if defaults.object(forKey: targetSizeBytesKey) != nil {
            let stored = Int64(defaults.integer(forKey: targetSizeBytesKey))
            bytes = (stored > 0 && stored <= TargetSizeLimit.maxBytes) ? stored : Int64(defaultTargetSizeBytes)
        } else {
            bytes = Int64(defaultTargetSizeBytes)
        }

        let unit: TargetSizeUnit
        if let raw = defaults.string(forKey: targetSizeUnitKey),
           let stored = TargetSizeUnit(rawValue: raw) {
            unit = stored
        } else {
            unit = defaultTargetSizeUnit
        }

        return TargetSizeLimit(bytes: bytes, unit: unit)
    }

    static func setTargetSizeLimit(_ limit: TargetSizeLimit, defaults: UserDefaults = .standard) {
        let clampedBytes = min(max(limit.bytes, 1), TargetSizeLimit.maxBytes)
        // Int is 64-bit on every supported platform, so this narrowing is exact.
        defaults.set(Int(clampedBytes), forKey: targetSizeBytesKey)
        defaults.set(limit.unit.rawValue, forKey: targetSizeUnitKey)
    }

    /// The flat background composited under transparent pixels when the target
    /// format has no alpha (e.g. JPEG). Stored normalized as uppercase `#RRGGBB`.
    /// Any value that isn't exactly a leading `#` plus six hex digits falls back to
    /// white.
    static func transparencyBackgroundHex(defaults: UserDefaults = .standard) -> String {
        guard let raw = defaults.string(forKey: transparencyBackgroundHexKey),
              let normalized = normalizeHexColor(raw) else {
            return defaultTransparencyBackgroundHex
        }
        return normalized
    }

    static func setTransparencyBackgroundHex(_ hex: String, defaults: UserDefaults = .standard) {
        let normalized = normalizeHexColor(hex) ?? defaultTransparencyBackgroundHex
        defaults.set(normalized, forKey: transparencyBackgroundHexKey)
    }

    /// Validate a `#RRGGBB` color and return it normalized to uppercase, or nil if
    /// it isn't a leading `#` followed by exactly six case-insensitive hex digits.
    private static func normalizeHexColor(_ raw: String) -> String? {
        guard raw.hasPrefix("#") else { return nil }
        let digits = raw.dropFirst()
        guard digits.count == 6,
              digits.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            return nil
        }
        return "#" + digits.uppercased()
    }
}
