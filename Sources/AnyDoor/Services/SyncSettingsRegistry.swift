import Foundation

/// Single source of truth for which UserDefaults keys are portable across
/// machines, plus their value type. Machine-specific keys
/// (`hyperKey.ownedSignatures`, `PortInventory.viewMode`, `SUSkippedVersion`)
/// are deliberately absent.
enum SyncSettingsRegistry {

    enum ValueType { case bool, int, string, stringArray }

    struct Entry {
        let key: String
        let type: ValueType
    }

    static let entries: [Entry] = [
        Entry(key: "menuBar.iconVisible", type: .bool),
        Entry(key: "menuBar.iconName", type: .string),
        Entry(key: "commandPalette.hotkey.keyCode", type: .int),
        Entry(key: "commandPalette.hotkey.modifierFlags", type: .int),
        Entry(key: "dev.bybee.AnyDoor.language", type: .string),
        Entry(key: "hyperKey.trigger", type: .string),
        Entry(key: "hyperKey.quickPress", type: .string),
        Entry(key: "hyperKey.includeShift", type: .bool),
        Entry(key: "scheduledShutdown.forced", type: .bool),
        Entry(key: "scheduledShutdown.warningLeadSeconds", type: .int),
        Entry(key: "scheduledShutdown.defaultMinutes", type: .int),
        Entry(key: "clipboard.customTags", type: .string),
        Entry(key: "clipboard.categoryOrder", type: .string),
        Entry(key: "clipboard.excludedBundleIDs", type: .stringArray),
        Entry(key: "pickColor.format", type: .string),
        Entry(key: "capture.saveDirectory", type: .string),
        Entry(key: "capture.namingTemplate", type: .string),
        Entry(key: "capture.autoCopy", type: .bool),
        Entry(key: "capture.autoSave", type: .bool),
        Entry(key: "capture.playSound", type: .bool),
        Entry(key: "capture.delaySeconds", type: .int),
        Entry(key: "capture.overlayTimeout", type: .int),
    ]

    private static let entriesByKey: [String: Entry] =
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })

    /// Collect whitelisted keys that are actually present in `defaults`.
    static func read(from defaults: UserDefaults) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for entry in entries {
            guard defaults.object(forKey: entry.key) != nil else { continue }
            switch entry.type {
            case .bool:   out[entry.key] = .bool(defaults.bool(forKey: entry.key))
            case .int:    out[entry.key] = .int(defaults.integer(forKey: entry.key))
            case .string:
                if let s = defaults.string(forKey: entry.key) {
                    out[entry.key] = .string(s)
                }
            case .stringArray:
                if let values = defaults.stringArray(forKey: entry.key) {
                    out[entry.key] = .stringArray(values)
                }
            }
        }
        return out
    }

    /// Write whitelisted values into `defaults`. Keys outside the whitelist and
    /// values whose type doesn't match the entry are ignored. Returns the number
    /// of values actually written.
    @discardableResult
    static func write(_ values: [String: SettingValue], to defaults: UserDefaults) -> Int {
        var applied = 0
        for (key, value) in values {
            guard let entry = entriesByKey[key] else { continue }
            switch (entry.type, value) {
            case (.bool, .bool(let v)):     defaults.set(v, forKey: key); applied += 1
            case (.int, .int(let v)):       defaults.set(v, forKey: key); applied += 1
            case (.string, .string(let v)): defaults.set(v, forKey: key); applied += 1
            case (.stringArray, .stringArray(let v)): defaults.set(v, forKey: key); applied += 1
            default: continue
            }
        }
        return applied
    }
}
