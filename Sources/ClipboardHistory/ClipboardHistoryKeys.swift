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
        case let status where Self.dependsOnKeychainLockState(status):
            return promptDeniedResult(status: status, keychain: keychain)
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
        case let status where Self.dependsOnKeychainLockState(status):
            return promptDeniedResult(status: status, keychain: keychain)
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
        case let status where Self.dependsOnKeychainLockState(status):
            return promptDeniedResult(status: status, keychain: keychain)
        default:
            return .failure(status)
        }
    }

    /// Which statuses mean nothing on their own and have to be read against the
    /// keychain's lock state. `errSecInteractionNotAllowed` covers two
    /// situations that must not be reported the same way: the keychain can
    /// genuinely be locked — temporary, resolves the moment the user unlocks it
    /// — or the item's ACL may not trust this caller while no authorization
    /// prompt can be shown, which never resolves on its own. A dismissed or
    /// failed password prompt is the same fork: on a still-locked keychain the
    /// user just waved the prompt away while busy, and calling that a denial
    /// puts "reset Clipboard History" — permanent data loss — in front of
    /// someone whose only problem is a locked keychain.
    static func dependsOnKeychainLockState(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    /// Reporting an ACL denial as `locked` would strand the user in a paused
    /// state that waits forever and offers no recovery, so an unlocked keychain
    /// downgrades a refused prompt to a denial the host can act on.
    private func promptDeniedResult(
        status: OSStatus,
        keychain: SecKeychain?
    ) -> ClipboardHistoryMasterKeyResult {
        // Under a policy that forbids prompting, `errSecInteractionNotAllowed`
        // says only that a prompt was needed; the caller can retry with one.
        // The other two statuses mean a prompt already happened and failed.
        if status == errSecInteractionNotAllowed, !allowsInteraction {
            return .interactionRequired
        }
        return Self.classifyInteractionNotAllowed(
            isKeychainUnlocked: Self.isKeychainUnlocked(keychain)
        )
    }

    /// `nil` means the lock state could not be determined; that keeps the
    /// temporary reading, which is the recoverable one.
    static func classifyInteractionNotAllowed(
        isKeychainUnlocked: Bool?
    ) -> ClipboardHistoryMasterKeyResult {
        isKeychainUnlocked == true ? .accessDenied : .locked
    }

    /// `SecKeychainGetStatus` is unavailable in the modern SDK headers, so it
    /// is resolved dynamically — the same technique the testing keychain hooks
    /// above use. A `nil` keychain asks about the default (login) keychain.
    static func isKeychainUnlocked(_ keychain: SecKeychain?) -> Bool? {
        guard
            let security = dlopen(
                "/System/Library/Frameworks/Security.framework/Security",
                RTLD_LAZY
            ),
            let symbol = dlsym(security, "SecKeychainGetStatus")
        else {
            return nil
        }
        defer { dlclose(security) }
        typealias GetStatus =
            @convention(c) (
                SecKeychain?,
                UnsafeMutablePointer<UInt32>
            ) -> OSStatus
        let getStatus = unsafeBitCast(symbol, to: GetStatus.self)
        var status: UInt32 = 0
        guard getStatus(keychain, &status) == errSecSuccess else {
            return nil
        }
        // kSecUnlockStateStatus
        return status & 1 != 0
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

/// The login keychain's lock state, read without touching the stored item — a
/// `load()` on a locked keychain would raise the password prompt, so a poll
/// that watches for the unlock has to ask this instead.
public enum ClipboardHistoryKeychainLock {
    /// `nil` when the state cannot be determined; the caller should treat that
    /// as "still locked" rather than acting on a guess.
    public static func isLoginKeychainUnlocked() -> Bool? {
        ClipboardHistoryKeychainStore.isKeychainUnlocked(nil)
    }
}

extension SymmetricKey {
    fileprivate var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
