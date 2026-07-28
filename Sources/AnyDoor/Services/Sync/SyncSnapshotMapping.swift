import Foundation

/// Pure mapping between backup-shaped configuration content and the flat
/// record map a `SyncDocument` holds. Sync and Config Backup share DTOs, so
/// this is the only place that knows which field is a record's identity.
enum SyncSnapshotMapping {

    /// The record-shaped view of a configuration, without clocks.
    struct Content: Equatable, Sendable {
        var appShortcuts: [AppShortcutDTO]
        var builtinPreferences: [BuiltinPreferenceDTO]
        var quicklinks: [QuicklinkDTO]
        var settings: [String: SettingValue]
    }

    /// Later duplicates win (matches `BackupService`'s prefer-the-last-row
    /// stance on duplicate bundle ids).
    static func payloads(from content: Content) -> [SyncKey: SyncPayload] {
        var out: [SyncKey: SyncPayload] = [:]
        for dto in content.appShortcuts {
            out[.appShortcut(bundleID: dto.appBundleID)] = .appShortcut(dto)
        }
        for dto in content.builtinPreferences {
            out[.builtinPreference(itemKey: dto.itemKey)] = .builtinPreference(dto)
        }
        for dto in content.quicklinks {
            out[.quicklink(id: dto.id)] = .quicklink(dto)
        }
        for (key, value) in content.settings {
            out[.setting(key: key)] = .setting(value)
        }
        return out
    }

    /// Rebuild content from a document's entries. Tombstones and entries
    /// whose payload kind doesn't match their key (corrupt or hostile peer
    /// file) are skipped, never trusted. Arrays come back in the export sort
    /// order (displayOrder, then identity) so the mapping round-trips.
    static func content(from entries: [SyncKey: SyncEntry]) -> Content {
        var shortcuts: [AppShortcutDTO] = []
        var prefs: [BuiltinPreferenceDTO] = []
        var quicklinks: [QuicklinkDTO] = []
        var settings: [String: SettingValue] = [:]

        for (key, entry) in entries {
            guard let payload = entry.payload else { continue }
            switch (key, payload) {
            case (.appShortcut(let bundleID), .appShortcut(var dto)):
                // The key is the identity; a payload disagreeing with it is
                // corrupt, so the key wins.
                dto.appBundleID = bundleID
                shortcuts.append(dto)
            case (.builtinPreference(let itemKey), .builtinPreference(var dto)):
                dto.itemKey = itemKey
                prefs.append(dto)
            case (.quicklink(let id), .quicklink(var dto)):
                dto.id = id
                quicklinks.append(dto)
            case (.setting(let key), .setting(let value)):
                settings[key] = value
            default:
                continue
            }
        }

        shortcuts.sort {
            ($0.displayOrder, $0.appBundleID) < ($1.displayOrder, $1.appBundleID)
        }
        prefs.sort {
            ($0.displayOrder, $0.itemKey) < ($1.displayOrder, $1.itemKey)
        }
        quicklinks.sort {
            ($0.displayOrder, $0.createdAt, $0.id.uuidString)
                < ($1.displayOrder, $1.createdAt, $1.id.uuidString)
        }

        return Content(
            appShortcuts: shortcuts,
            builtinPreferences: prefs,
            quicklinks: quicklinks,
            settings: settings
        )
    }
}
