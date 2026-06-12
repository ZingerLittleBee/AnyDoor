import Foundation
import Observation

/// A user-defined clipboard category. The id is a UUID string and stays
/// stable across renames; items reference tags by id (`ClipboardHistoryItem
/// .tagIDs`), so renaming touches only this registry.
struct ClipboardTag: Codable, Equatable, Identifiable {
    let id: String
    var name: String
}

/// Registry of user-defined clipboard categories. Definitions are a small
/// JSON array persisted as a string under one UserDefaults key so they ride
/// the existing settings backup (`SyncSettingsRegistry`); membership lives on
/// the items themselves and stays machine-local, like clipboard history.
@MainActor
@Observable
final class ClipboardTagStore {
    static let shared = ClipboardTagStore()
    static let defaultsKey = "clipboard.customTags"

    @ObservationIgnored private let defaults: UserDefaults
    /// Array order is display order (creation order; no manual reordering).
    private(set) var tags: [ClipboardTag] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    /// Re-read from UserDefaults (used after a settings backup import).
    func reload() {
        guard let json = defaults.string(forKey: Self.defaultsKey),
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ClipboardTag].self, from: data)
        else {
            tags = []
            return
        }
        tags = decoded
    }

    func name(for id: String) -> String? {
        tags.first { $0.id == id }?.name
    }

    /// Creates a tag with the trimmed name. Returns nil for an empty name;
    /// returns the existing tag instead of creating a duplicate name.
    /// The duplicate check is an exact string match (case- and
    /// normalization-sensitive) by design.
    @discardableResult
    func createTag(name: String) -> ClipboardTag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = tags.first(where: { $0.name == trimmed }) { return existing }
        let tag = ClipboardTag(id: UUID().uuidString, name: trimmed)
        tags.append(tag)
        persist()
        return tag
    }

    /// Renames in place. Empty names and names already used by another tag
    /// are rejected (no-op) so the registry never holds ambiguous entries.
    func renameTag(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !tags.contains(where: { $0.id != id && $0.name == trimmed }),
              let index = tags.firstIndex(where: { $0.id == id })
        else { return }
        tags[index].name = trimmed
        persist()
    }

    /// Removes the definition only. The caller is responsible for sweeping the
    /// id off items (`ClipboardHistoryStore.removeTagFromAllItems`) so they
    /// regain prunability; a launch-time sweep covers crash gaps.
    func deleteTag(id: String) {
        tags.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(tags),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Self.defaultsKey)
    }
}
