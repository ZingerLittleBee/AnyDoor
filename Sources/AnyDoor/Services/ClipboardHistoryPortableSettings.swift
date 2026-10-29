import ClipboardHistory
import Foundation

struct ClipboardTag: Codable, Equatable, Identifiable {
    let id: String
    var name: String
}

enum ClipboardHistoryPortableKeys {
    static let customTags = "clipboard.customTags"
}

@MainActor
enum ClipboardHistoryPortableSettings {
    static func legacyTagPreference(from defaults: UserDefaults) throws -> ClipboardHistoryLegacyTagPreference {
        guard let value = defaults.object(forKey: ClipboardHistoryPortableKeys.customTags) else {
            return .init(format: .json, data: Data("[]".utf8))
        }
        if let json = value as? String {
            return .init(format: .json, data: Data(json.utf8))
        }
        // UserDefaults values are property lists. Preserve their type and value
        // rather than replacing a malformed legacy setting with empty bytes.
        return .init(format: .propertyList, data: try PropertyListSerialization.data(
            fromPropertyList: value, format: .binary, options: 0))
    }

    static func encode(_ definitions: [ClipboardHistoryTagDefinition]) throws -> String {
        let tags = definitions.map {
            ClipboardTag(id: $0.id, name: $0.displayName)
        }
        let data = try JSONEncoder().encode(tags)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return json
    }

    static func definitions(from json: String) throws -> [ClipboardHistoryTagDefinition] {
        let tags = try JSONDecoder().decode(
            [ClipboardTag].self,
            from: Data(json.utf8)
        )
        let definitions = tags.map {
            ClipboardHistoryTagDefinition(
                id: $0.id,
                displayName: $0.name
            )
        }
        guard Set(definitions.map(\.id)).count == definitions.count else {
            throw ClipboardHistoryModuleError.invalidTagIDs(
                Set(definitions.map(\.id))
            )
        }
        return definitions
    }
}
