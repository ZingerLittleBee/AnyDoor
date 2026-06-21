import Foundation
import Security

/// Thin Keychain wrapper for per-instance LLM API keys. Each secret is stored as
/// a `kSecClassGenericPassword` item keyed by `account = id` under the injected
/// `service` string. Secrets live ONLY here and are excluded from backup/sync.
struct TranslationKeychainStore {
    private let service: String

    init(service: String = "dev.bybee.AnyDoor.translation") {
        self.service = service
    }

    /// Upsert: delete any existing item for `id`, then add the new value.
    /// A no-op (empty) value is treated as a delete so we never persist "".
    func setAPIKey(_ key: String, for id: String) {
        deleteAPIKey(for: id)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func apiKey(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func deleteAPIKey(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
