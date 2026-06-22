import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "translation.keychain")

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
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("SecItemAdd failed for translation API key: OSStatus \(status, privacy: .public)")
        }
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
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is benign (nothing to delete); anything else is a fault.
        if status != errSecSuccess, status != errSecItemNotFound {
            logger.error("SecItemDelete failed for translation API key: OSStatus \(status, privacy: .public)")
        }
    }
}
