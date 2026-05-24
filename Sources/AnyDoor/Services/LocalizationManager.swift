import Foundation
import Observation

/// User-facing language preference. `.system` follows macOS preferred languages
/// (resolved against the app's supported set); the others force a specific locale.
enum LanguagePreference: String, CaseIterable, Sendable {
    case system
    case zh
    case en
}

/// Resolves the active locale + resource bundle so all UI strings can be
/// re-localized without a relaunch. SwiftUI views observe this object to
/// re-render when the preference changes.
@MainActor
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    static let defaultsKey = "dev.bybee.AnyDoor.language"

    private let preferredLanguagesProvider: @Sendable () -> [String]
    private let defaults: UserDefaults

    // Manual UserDefaults injection (rather than @AppStorage) so tests can
    // supply an isolated suite and exercise the persistence round-trip.
    init(
        defaults: UserDefaults = .standard,
        preferredLanguagesProvider: @escaping @Sendable () -> [String] = { Locale.preferredLanguages }
    ) {
        self.defaults = defaults
        self.preferredLanguagesProvider = preferredLanguagesProvider
        if let raw = defaults.string(forKey: Self.defaultsKey),
           let parsed = LanguagePreference(rawValue: raw) {
            self._preference = parsed
        } else {
            self._preference = .system
        }
    }

    private var _preference: LanguagePreference

    var preference: LanguagePreference {
        get { _preference }
        set {
            guard newValue != _preference else { return }
            _preference = newValue
            defaults.set(newValue.rawValue, forKey: Self.defaultsKey)
        }
    }

    /// The resolved `Locale` to apply via `String(localized:locale:)` and SwiftUI's `\.locale`.
    var effectiveLocale: Locale {
        Locale(identifier: resolvedLocaleIdentifier())
    }

    /// The resource bundle scoped to `effectiveLocale`. Strings looked up via
    /// `String(localized:bundle:locale:)` against this bundle re-resolve on
    /// preference change, bypassing the process-locked `Bundle.main` lookup.
    var bundle: Bundle {
        let id = resolvedLocaleIdentifier()
        if let path = Bundle.module.path(forResource: id, ofType: "lproj"),
           let lprojBundle = Bundle(path: path) {
            return lprojBundle
        }
        return Bundle.module
    }

    private func resolvedLocaleIdentifier() -> String {
        switch _preference {
        case .zh: return "zh-Hans"
        case .en: return "en"
        case .system:
            for code in preferredLanguagesProvider() {
                if let match = Self.matchSupportedLocale(for: code) {
                    return match
                }
            }
            return "en"
        }
    }

    private static func matchSupportedLocale(for languageCode: String) -> String? {
        let normalized = languageCode.lowercased()
        if normalized.hasPrefix("zh") { return "zh-Hans" }
        if normalized.hasPrefix("en") { return "en" }
        return nil
    }
}
