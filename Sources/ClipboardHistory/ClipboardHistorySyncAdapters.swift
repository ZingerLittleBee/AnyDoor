import Foundation
import CryptoKit

/// Only external services are replaceable. Persistence and domain decisions stay
/// in ClipboardHistoryModule, including in two-device integration tests.
struct ClipboardSyncAccount: Codable, Equatable, Sendable {
    let container: String
    let environment: String
    let owner: String

    var identifier: String {
        let components = [container, environment, owner]
        let input = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

struct ClipboardSyncControl: Codable, Equatable, Sendable {
    let accountID: String
    let keyID: UUID
    let keyCheck: Data
    let epoch: UUID
    let phase: String
    /// Opaque adapter-owned system fields used for server compare-and-swap.
    let serverToken: Data?
}

enum ClipboardSyncRecordKind: String, Codable, Sendable {
    case tag
    case entry
    case fileBody
}

struct ClipboardSyncRemoteRecord: Codable, Equatable, Sendable {
    let recordID: String
    let operationID: UUID
    let epoch: UUID
    let keyID: UUID
    let kind: ClipboardSyncRecordKind
    let chunkCount: Int
    let encryptedByteCount: Int64
    let digest: Data
}

struct ClipboardSyncChanges: Sendable {
    let records: [ClipboardSyncRemoteRecord]
    let cursor: Data?
    let hasMore: Bool
}

struct ClipboardSyncUpload: Codable, Equatable, Sendable {
    let record: ClipboardSyncRemoteRecord
    /// Independently authenticated encrypted units, never plaintext CKAssets.
    let chunks: [Data]
}

struct ClipboardSyncCleanupPage: Sendable {
    let control: ClipboardSyncControl
    let cursor: Data?
    let deletedRecordCount: Int
    let hasMore: Bool
}

enum ClipboardSyncServiceError: Error, Equatable, Sendable {
    case accountUnavailable
    case accountChanged
    case capabilityUnavailable
    case keyLocked
    case keyUnavailable
    case accessDenied
    case network(retryAfter: TimeInterval?)
    case quota
    case localStorage
    case conflict
    case missingRemoteState
    case corruptData
    case unsupportedVersion
}

protocol ClipboardSyncTransport: Sendable {
    func account() async throws -> ClipboardSyncAccount
    func control(for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl?
    /// Creates only when absent. On a competing initializer, returns the
    /// authoritative winner; never replaces an existing key identity.
    func createControl(
        _ candidate: ClipboardSyncControl, for account: ClipboardSyncAccount
    ) async throws -> ClipboardSyncControl
    /// Metadata discovery MUST exclude CKAsset fields. Download is separate.
    func changes(
        for account: ClipboardSyncAccount, control: ClipboardSyncControl, cursor: Data?
    ) async throws -> ClipboardSyncChanges
    func download(
        _ record: ClipboardSyncRemoteRecord, for account: ClipboardSyncAccount
    ) async throws -> [Data]
    /// Commits immutable content and advances control in the same atomic custom
    /// zone CAS. Replay of the same operation/digest is success; another epoch
    /// or a stale control never permits an unconditional overwrite.
    func commit(
        _ upload: ClipboardSyncUpload,
        for account: ClipboardSyncAccount,
        control: ClipboardSyncControl
    ) async throws -> ClipboardSyncControl
    func cancel() async
    /// Conditional phase transition on the permanent authority record.
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
                    for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl
    /// Deletes a bounded metadata-only page with the resetting control CAS in
    /// the same atomic operation. Never removes the zone or control record.
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl,
                   cursor: Data?) async throws -> ClipboardSyncCleanupPage
}

extension ClipboardSyncTransport {
    func transition(_ control: ClipboardSyncControl, to phase: String, epoch: UUID,
                    for account: ClipboardSyncAccount) async throws -> ClipboardSyncControl {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
    func clearPage(for account: ClipboardSyncAccount, control: ClipboardSyncControl,
                   cursor: Data?) async throws -> ClipboardSyncCleanupPage {
        throw ClipboardSyncServiceError.capabilityUnavailable
    }
}

protocol ClipboardSyncKeyStoring: Sendable {
    func load(account: ClipboardSyncAccount, keyID: UUID) async throws -> Data?
    /// Immutable UUID-scoped candidate. Existing unequal bytes must fail closed.
    func create(account: ClipboardSyncAccount, keyID: UUID, key: Data) async throws -> Data
}

struct ClipboardSyncServices: Sendable {
    let transport: any ClipboardSyncTransport
    let keys: any ClipboardSyncKeyStoring
    /// Nil uses explicit retry in isolated tests; production schedules retries.
    let pollingInterval: Duration?
}
