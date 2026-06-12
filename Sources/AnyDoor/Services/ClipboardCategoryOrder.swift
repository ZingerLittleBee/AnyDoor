import Foundation

/// Persists the clipboard wall's tab order. The user reorders tabs by
/// ⌘-dragging the capsules; the result is stored as a JSON array of stable
/// category ids (`ClipboardWallCategory.persistentID`) under one UserDefaults
/// key so it rides the settings backup (`SyncSettingsRegistry`) alongside the
/// tag definitions it references.
enum ClipboardCategoryOrder {
    static let defaultsKey = "clipboard.categoryOrder"

    /// Reorders `available` to follow the persisted id order: persisted ids
    /// that still resolve come first (in persisted order); categories the
    /// persisted list doesn't know (newly created tags, builtin tabs added in
    /// an update) are appended keeping their default relative order. Stale
    /// persisted ids (deleted tags) drop out.
    static func merge(
        persistedIDs: [String],
        available: [ClipboardWallCategory]
    ) -> [ClipboardWallCategory] {
        let byID = Dictionary(available.map { ($0.persistentID, $0) },
                              uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var ordered: [ClipboardWallCategory] = []
        for id in persistedIDs {
            guard let category = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(category)
        }
        ordered.append(contentsOf: available.filter { !seen.contains($0.persistentID) })
        return ordered
    }

    /// `merge` against the order stored in `defaults`.
    static func apply(
        to available: [ClipboardWallCategory],
        defaults: UserDefaults = .standard
    ) -> [ClipboardWallCategory] {
        merge(persistedIDs: load(from: defaults), available: available)
    }

    static func load(from defaults: UserDefaults = .standard) -> [String] {
        guard let json = defaults.string(forKey: defaultsKey),
              let ids = try? JSONDecoder().decode([String].self, from: Data(json.utf8))
        else { return [] }
        return ids
    }

    static func save(_ categories: [ClipboardWallCategory], to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(categories.map(\.persistentID)),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: defaultsKey)
    }
}
