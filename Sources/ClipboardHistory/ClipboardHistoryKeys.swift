import CryptoKit
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
    case accessDenied
    case failure(OSStatus)
}

protocol ClipboardHistoryMasterKeyStoring: Sendable {
    func load() -> ClipboardHistoryMasterKeyResult
    func create() -> ClipboardHistoryMasterKeyResult
    func delete() -> ClipboardHistoryMasterKeyResult
}

final class ClipboardHistoryKeychainStore:
    ClipboardHistoryMasterKeyStoring,
    @unchecked Sendable
{
    static let service = "dev.bybee.AnyDoor.ClipboardHistory"
    static let account = "device-master-key-v1"

    enum ProcessIdentity: Equatable, Sendable {
        case development
        case installed
    }

    enum CrossIdentityAccess: Equatable, Sendable {
        case silent
        case mayPrompt
    }

    static var readQuery: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = false
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
    }

    static func addAttributes(key: Data) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key,
        ]
    }

    static func crossIdentityAccess(
        creator: ProcessIdentity,
        accessor: ProcessIdentity
    ) -> CrossIdentityAccess {
        creator == accessor ? .silent : .mayPrompt
    }

    func load() -> ClipboardHistoryMasterKeyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(Self.readQuery as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let key = result as? Data, key.count == 32 else {
                return .failure(errSecDecode)
            }
            return .key(key)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .locked
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

        let status = SecItemAdd(
            Self.addAttributes(key: key) as CFDictionary,
            nil
        )
        switch status {
        case errSecSuccess:
            return .key(key)
        case errSecDuplicateItem:
            return load()
        case errSecInteractionNotAllowed:
            return .locked
        case errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .failure(status)
        }
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        var query = Self.readQuery
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed:
            return .locked
        case errSecAuthFailed, errSecUserCanceled:
            return .accessDenied
        default:
            return .failure(status)
        }
    }
}

extension SymmetricKey {
    fileprivate var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
