import ClipboardHistory
import Foundation

@MainActor
enum ClipboardHistoryPortableSettings {
    static func persist(
        _ definitions: [ClipboardHistoryTagDefinition],
        to defaults: UserDefaults = .standard
    ) throws {
        let tags = definitions.map {
            ClipboardTag(id: $0.id, name: $0.displayName)
        }
        let data = try JSONEncoder().encode(tags)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        defaults.set(json, forKey: ClipboardTagStore.defaultsKey)
        NotificationCenter.default.post(
            name: .portableConfigDidChange,
            object: nil
        )
    }

    static func reconcile(
        module: ClipboardHistoryModule,
        defaults: UserDefaults = .standard
    ) async throws {
        let definitions = try definitions(from: defaults)
        _ = try await module.replaceTagDefinitions(with: definitions)
    }

    static func definitions(
        from defaults: UserDefaults
    ) throws -> [ClipboardHistoryTagDefinition] {
        guard
            let json = defaults.string(
                forKey: ClipboardTagStore.defaultsKey
            )
        else {
            return []
        }
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
