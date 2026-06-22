import Foundation
import OSLog
import Security

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "translation.keychain")

/// Process-wide memo of resolved secrets, keyed by `service` + `account`. The
/// translation run path rebuilds its providers on every translate (including a
/// language swap), so without this each translate would hit the Keychain again —
/// which, on a dev build whose code signature isn't in the item's ACL, re-prompts
/// for the login password every time. Reads populate it; writes/deletes
/// invalidate it. Lock-guarded so it stays correct off the MainActor (tests).
private final class KeychainValueCache: @unchecked Sendable {
    static let shared = KeychainValueCache()
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }

    func remove(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}

/// Thin Keychain wrapper for per-instance LLM API keys. Each secret is stored as
/// a `kSecClassGenericPassword` item keyed by `account = id` under the injected
/// `service` string. Secrets live ONLY here and are excluded from backup/sync.
/// Resolved values are cached in memory (see `KeychainValueCache`) so repeated
/// reads during translation don't re-prompt for Keychain access.
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
        if status == errSecSuccess {
            KeychainValueCache.shared.set(cacheKey(id), trimmed)
        } else {
            logger.error("SecItemAdd failed for translation API key: OSStatus \(status, privacy: .public)")
        }
    }

    func apiKey(for id: String) -> String? {
        if let cached = KeychainValueCache.shared.get(cacheKey(id)) { return cached }
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
        KeychainValueCache.shared.set(cacheKey(id), value)
        return value
    }

    func deleteAPIKey(for id: String) {
        KeychainValueCache.shared.remove(cacheKey(id))
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

    /// Cache key scoped by service so two stores with different services never
    /// alias (mirrors the Keychain's own service/account scoping).
    private func cacheKey(_ id: String) -> String {
        service + "\u{0}" + id
    }
}
