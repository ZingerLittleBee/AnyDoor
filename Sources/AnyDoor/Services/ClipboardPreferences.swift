import ClipboardHistory
import Foundation

enum ClipboardRetention: Int, CaseIterable, Sendable {
    case oneDay = 1
    case sevenDays = 7
    case thirtyDays = 30
    case ninetyDays = 90
    case oneHundredEightyDays = 180
    case threeHundredSixtyFiveDays = 365
    case unlimited = 0

    var maxAge: TimeInterval {
        switch self {
        case .unlimited: return .infinity
        case .oneDay: return 86_400
        case .sevenDays: return 7 * 86_400
        case .thirtyDays: return 30 * 86_400
        case .ninetyDays: return 90 * 86_400
        case .oneHundredEightyDays: return 180 * 86_400
        case .threeHundredSixtyFiveDays: return 365 * 86_400
        }
    }

    var titleKey: L10n.Key {
        switch self {
        case .oneDay: return .settingsClipboardRetention1
        case .sevenDays:  return .settingsClipboardRetention7
        case .thirtyDays: return .settingsClipboardRetention30
        case .ninetyDays: return .settingsClipboardRetention90
        case .oneHundredEightyDays:
            return .settingsClipboardRetention180
        case .threeHundredSixtyFiveDays:
            return .settingsClipboardRetention365
        case .unlimited:  return .settingsClipboardRetentionUnlimited
        }
    }

    var modulePeriod: ClipboardHistoryRetentionPeriod {
        switch self {
        case .oneDay: .oneDay
        case .sevenDays: .sevenDays
        case .thirtyDays: .thirtyDays
        case .ninetyDays: .ninetyDays
        case .oneHundredEightyDays: .oneHundredEightyDays
        case .threeHundredSixtyFiveDays: .threeHundredSixtyFiveDays
        case .unlimited: .unlimited
        }
    }
}

/// Typed UserDefaults accessors for clipboard settings. Keys are namespaced
/// `clipboard.*` and read by the watcher, store bootstrap, and paste service.
enum ClipboardPreferences {
    static let monitoringKey = "clipboard.monitoringEnabled"
    static let copyOnlyKey = "clipboard.copyOnly"
    static let retentionKey = "clipboard.retentionDays"
    static let excludedKey = "clipboard.excludedBundleIDs"
    static let ignoresUniversalClipboardKey =
        "clipboard.ignoresUniversalClipboard"
    static let defaultExclusionsMergeKey =
        "clipboard.defaultExclusionsMergedV1"

    static let defaultExcludedBundleIDs = [
        "com.apple.Passwords",
        "com.apple.keychainaccess",
    ]

    // `UserDefaults.standard` is fetched per access (it is not `Sendable`, so it
    // cannot be cached in a static `let` under Swift 6 strict concurrency).
    private static var defaults: UserDefaults { .standard }

    static var monitoringEnabled: Bool { monitoringEnabled(from: defaults) }
    static var copyOnly: Bool { copyOnly(from: defaults) }
    static var retention: ClipboardRetention {
        ClipboardRetention(rawValue: defaults.object(forKey: retentionKey) as? Int ?? 30) ?? .thirtyDays
    }
    static var excludedBundleIDs: Set<String> { Set(excludedBundleIDs(from: defaults)) }
    static var ignoresUniversalClipboard: Bool {
        ignoresUniversalClipboard(from: defaults)
    }

    static func excludedBundleIDs(from defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: excludedKey) ?? []
    }

    static func monitoringEnabled(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: monitoringKey) as? Bool ?? true
    }

    static func copyOnly(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: copyOnlyKey) as? Bool ?? false
    }

    static func ignoresUniversalClipboard(
        from defaults: UserDefaults = .standard
    ) -> Bool {
        defaults.object(forKey: ignoresUniversalClipboardKey) as? Bool ?? false
    }

    static func setMonitoringEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: monitoringKey)
    }

    static func setCopyOnly(
        _ enabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: copyOnlyKey)
    }

    static func setIgnoresUniversalClipboard(
        _ ignored: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(ignored, forKey: ignoresUniversalClipboardKey)
    }

    static func mergeDefaultExclusionsIfNeeded(
        in defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: defaultExclusionsMergeKey) else {
            return
        }
        var exclusions = excludedBundleIDs(from: defaults)
        for bundleID in defaultExcludedBundleIDs
        where !exclusions.contains(bundleID) {
            exclusions.append(bundleID)
        }
        defaults.set(exclusions, forKey: excludedKey)
        defaults.set(true, forKey: defaultExclusionsMergeKey)
    }

    static func monitoringConfiguration(
        from defaults: UserDefaults = .standard
    ) -> ClipboardHistoryMonitoringConfiguration {
        ClipboardHistoryMonitoringConfiguration(
            excludedBundleIdentifiers: Set(
                excludedBundleIDs(from: defaults)
            ),
            ignoresUniversalClipboard: ignoresUniversalClipboard(
                from: defaults
            )
        )
    }

    static func addExcludedBundleID(_ rawBundleID: String, to defaults: UserDefaults = .standard) {
        let bundleID = rawBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }

        var ids = excludedBundleIDs(from: defaults)
        guard !ids.contains(bundleID) else { return }
        ids.append(bundleID)
        defaults.set(ids, forKey: excludedKey)
    }

    static func removeExcludedBundleID(_ bundleID: String, from defaults: UserDefaults = .standard) {
        let ids = excludedBundleIDs(from: defaults).filter { $0 != bundleID }
        defaults.set(ids, forKey: excludedKey)
    }
}
