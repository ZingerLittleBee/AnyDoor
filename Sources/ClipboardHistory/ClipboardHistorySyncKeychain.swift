import Foundation
import LocalAuthentication
import Security

/// Restricted services are never constructed before this process's signed
/// capabilities have been checked. Ad-hoc builds keep local history usable.
enum ClipboardSyncNativeConfiguration {
    static let container = "iCloud.dev.bybee.AnyDoor"
    static let environment = "Production"
    static let accessGroup = "9VM4RM39R3.dev.bybee.AnyDoor"
    static let team = "9VM4RM39R3"

    static func requireCapabilities() throws {
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                &information
              ) == errSecSuccess,
              let information = information as? [String: Any],
              information[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let entitlements = information[kSecCodeInfoEntitlementsDict as String]
                as? [String: Any],
              entitlements["com.apple.application-identifier"] as? String == accessGroup,
              entitlements["com.apple.developer.team-identifier"] as? String == team,
              entitlements["com.apple.developer.icloud-container-environment"]
                as? String == environment,
              let containers = entitlements["com.apple.developer.icloud-container-identifiers"]
                as? [String], containers.contains(container),
              let services = entitlements["com.apple.developer.icloud-services"]
                as? [String], services.contains("CloudKit"),
              let groups = entitlements["keychain-access-groups"] as? [String],
              groups.contains(accessGroup)
        else {
            throw ClipboardSyncServiceError.capabilityUnavailable
        }
    }

    static func validate(_ account: ClipboardSyncAccount) throws {
        guard account.container == container, account.environment == environment,
              !account.owner.isEmpty, account.owner != "__defaultOwner__"
        else {
            throw ClipboardSyncServiceError.accountChanged
        }
    }
}

/// UUID-scoped keys are immutable. There is intentionally no update or delete
/// operation: local participation never owns the shared key's lifetime.
actor ClipboardSyncKeychain: ClipboardSyncKeyStoring {
    private static let service = "dev.bybee.AnyDoor.ClipboardSync.key.v1"

    func load(account: ClipboardSyncAccount, keyID: UUID) throws -> Data? {
        try ClipboardSyncNativeConfiguration.requireCapabilities()
        try ClipboardSyncNativeConfiguration.validate(account)
        try Task.checkCancellation()
        var query = attributes(account: account, keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Self.failure(status) }
        guard let key = result as? Data, key.count == 32 else {
            throw ClipboardSyncServiceError.corruptData
        }
        return key
    }

    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) throws -> Data {
        try ClipboardSyncNativeConfiguration.requireCapabilities()
        try ClipboardSyncNativeConfiguration.validate(account)
        try Task.checkCancellation()
        guard key.count == 32 else { throw ClipboardSyncServiceError.corruptData }
        var query = attributes(account: account, keyID: keyID)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecValueData as String] = key
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw Self.failure(status)
        }
        guard let persisted = try load(account: account, keyID: keyID),
              persisted == key
        else {
            throw ClipboardSyncServiceError.corruptData
        }
        return persisted
    }

    private func attributes(account: ClipboardSyncAccount, keyID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "v1.\(account.identifier).\(keyID.uuidString.lowercased())",
            kSecAttrAccessGroup as String: ClipboardSyncNativeConfiguration.accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: true,
        ]
    }

    private static func failure(_ status: OSStatus) -> ClipboardSyncServiceError {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable:
            .keyLocked
        case errSecAuthFailed, errSecUserCanceled:
            .accessDenied
        case errSecMissingEntitlement:
            .capabilityUnavailable
        case errSecDecode:
            .corruptData
        default:
            .accessDenied
        }
    }
}

extension ClipboardSyncServices {
    static func production() -> ClipboardSyncServices {
        ClipboardSyncServices(
            transport: ClipboardSyncCloudKit(),
            keys: ClipboardSyncKeychain(),
            pollingInterval: .seconds(30)
        )
    }
}
