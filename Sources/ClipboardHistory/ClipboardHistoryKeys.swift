import CryptoKit
import Darwin
import Foundation
import LocalAuthentication
import Security

struct ClipboardHistoryDerivedKeys: Equatable, Sendable {
    let version: Int
    let databaseKey: Data
    let payloadKey: Data
}

enum ClipboardHistoryKeyDerivation {
    private static let v1Salt = Data(
        "dev.bybee.AnyDoor.ClipboardHistory.hkdf.v1".utf8
    )
    private static let databaseContext = Data("sqlcipher-key".utf8)
    private static let payloadContext = Data("aes-gcm-payload-key".utf8)

    static func deriveV1(from masterKey: Data) -> ClipboardHistoryDerivedKeys {
        let inputKey = SymmetricKey(data: masterKey)
        let databaseKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: v1Salt,
            info: databaseContext,
            outputByteCount: 32
        )
        let payloadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: v1Salt,
            info: payloadContext,
            outputByteCount: 32
        )

        return ClipboardHistoryDerivedKeys(
            version: 1,
            databaseKey: databaseKey.data,
            payloadKey: payloadKey.data
        )
    }
}

enum ClipboardHistoryMasterKeyResult: Equatable, Sendable {
    case key(Data)
    case missing
    case locked
    case interactionRequired
    case accessDenied
    case failure(OSStatus)
}

protocol ClipboardHistoryMasterKeyStoring: Sendable {
    func load() -> ClipboardHistoryMasterKeyResult
    func create() -> ClipboardHistoryMasterKeyResult
    func delete() -> ClipboardHistoryMasterKeyResult
}

struct ClipboardHistoryKeychainStore: ClipboardHistoryMasterKeyStoring {
    static let service = "dev.bybee.AnyDoor.ClipboardHistory"
    static let account = "device-master-key-v1"

    private let testingKeychainPath: String?
    private let allowsInteraction: Bool

    init() {
        testingKeychainPath = nil
        allowsInteraction = true
    }

    init(testingKeychainPath: String, allowsInteraction: Bool) {
        self.testingKeychainPath = testingKeychainPath
        self.allowsInteraction = allowsInteraction
    }

    static var readQuery: [String: Any] {
        readQuery(allowsInteraction: true, keychain: nil)
    }

    private static func readQuery(
        allowsInteraction: Bool,
        keychain: SecKeychain?
    ) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !allowsInteraction
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        if let keychain {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    static func addAttributes(key: Data) -> [String: Any] {
        addAttributes(key: key, keychain: nil)
    }

    private static func addAttributes(
        key: Data,
        keychain: SecKeychain?
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
        ]
        if let keychain {
            attributes[kSecUseKeychain as String] = keychain
        }
        return attributes
    }

    func load() -> ClipboardHistoryMasterKeyResult {
        guard prepareTestingInteractionPolicy() == errSecSuccess else {
            return .failure(errSecUnimplemented)
        }
        let keychain: SecKeychain?
        switch openTestingKeychain() {
        case .success(let openedKeychain):
            keychain = openedKeychain
        case .failure(let status):
            return .failure(status)
        }
        var result: CFTypeRef?
        let query = Self.readQuery(
            allowsInteraction: allowsInteraction,
            keychain: keychain
        )
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let key = result as? Data, key.count == 32 else {
                return .failure(errSecDecode)
            }
            return .key(key)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return allowsInteraction ? .locked : .interactionRequired
        case errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .failure(status)
        }
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        switch load() {
        case .missing:
            break
        case let existing:
            return existing
        }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else {
            return .failure(randomStatus)
        }

        let keychain: SecKeychain?
        switch openTestingKeychain() {
        case .success(let openedKeychain):
            keychain = openedKeychain
        case .failure(let status):
            return .failure(status)
        }
        let status = SecItemAdd(
            Self.addAttributes(key: key, keychain: keychain) as CFDictionary,
            nil
        )
        switch status {
        case errSecSuccess:
            return .key(key)
        case errSecDuplicateItem:
            return load()
        case errSecInteractionNotAllowed:
            return allowsInteraction ? .locked : .interactionRequired
        case errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .failure(status)
        }
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        guard prepareTestingInteractionPolicy() == errSecSuccess else {
            return .failure(errSecUnimplemented)
        }
        let keychain: SecKeychain?
        switch openTestingKeychain() {
        case .success(let openedKeychain):
            keychain = openedKeychain
        case .failure(let status):
            return .failure(status)
        }
        var query = Self.readQuery(
            allowsInteraction: allowsInteraction,
            keychain: keychain
        )
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return allowsInteraction ? .locked : .interactionRequired
        case errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .failure(status)
        }
    }

    private enum KeychainOpenResult {
        case success(SecKeychain?)
        case failure(OSStatus)
    }

    private func openTestingKeychain() -> KeychainOpenResult {
        guard let testingKeychainPath else {
            return .success(nil)
        }
        var keychain: SecKeychain?
        guard
            let security = dlopen(
                "/System/Library/Frameworks/Security.framework/Security",
                RTLD_LAZY
            ),
            let symbol = dlsym(security, "SecKeychainOpen")
        else {
            return .failure(errSecUnimplemented)
        }
        defer { dlclose(security) }
        typealias OpenKeychain =
            @convention(c) (
                UnsafePointer<CChar>,
                UnsafeMutablePointer<SecKeychain?>
            ) -> OSStatus
        let openKeychain = unsafeBitCast(symbol, to: OpenKeychain.self)
        let status = testingKeychainPath.withCString {
            openKeychain($0, &keychain)
        }
        guard status == errSecSuccess else {
            return .failure(status)
        }
        return .success(keychain)
    }

    private func prepareTestingInteractionPolicy() -> OSStatus {
        guard testingKeychainPath != nil, !allowsInteraction else {
            return errSecSuccess
        }
        guard
            let security = dlopen(
                "/System/Library/Frameworks/Security.framework/Security",
                RTLD_LAZY
            ),
            let symbol = dlsym(
                security,
                "SecKeychainSetUserInteractionAllowed"
            )
        else {
            return errSecUnimplemented
        }
        defer { dlclose(security) }
        typealias SetInteractionAllowed =
            @convention(c) (DarwinBoolean)
            -> OSStatus
        let setInteractionAllowed = unsafeBitCast(
            symbol,
            to: SetInteractionAllowed.self
        )
        return setInteractionAllowed(false)
    }
}

extension SymmetricKey {
    fileprivate var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
