import CryptoKit
import Foundation

struct ClipboardSyncTagContent: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

struct ClipboardSyncTextContent: Codable, Equatable, Sendable {
    let id: UUID
    let text: String
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceDisplayName: String?
    let sourceProvenance: String
    let favorite: Bool
    let tags: [ClipboardSyncTagContent]
}

enum ClipboardSyncContent: Codable, Equatable, Sendable {
    case deletion(ClipboardSyncDeletion)
    case withdrawal(ClipboardSyncWithdrawal)
    case rejoin(ClipboardSyncRejoin)
    case tag(ClipboardSyncTagContent)
    case text(ClipboardSyncTextContent)
    case textEdit(ClipboardSyncTextEditContent)
    case entry(ClipboardSyncEntryContent)
    case metadata(ClipboardSyncMetadataContent)
    case tagMembership(ClipboardSyncTagMembership)
    case tagState(ClipboardSyncTagState)
    case fileBody(ClipboardSyncFileBody)
    case tagMerge(ClipboardSyncTagMerge)
}

enum ClipboardSyncCodec {
    static let chunkByteCount = 4 * 1_024 * 1_024

    static func check(key: Data, account: ClipboardSyncAccount, keyID: UUID) -> Data {
        let value = Data("clipboard-sync-key-v1:\(account.identifier):\(keyID.uuidString)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: value, using: derivedKey(key, purpose: "key-check")))
    }

    static func seal(
        _ content: ClipboardSyncContent, account: ClipboardSyncAccount,
        control: ClipboardSyncControl, key: Data, operationID: UUID = UUID()
    ) throws -> ClipboardSyncUpload {
        let kind: ClipboardSyncRecordKind = switch content {
        case .tag, .tagMembership, .tagState, .tagMerge, .withdrawal: .tag
        case .text, .textEdit, .entry, .metadata, .deletion, .rejoin: .entry
        case .fileBody: .fileBody
        }
        let plaintext = try JSONEncoder().encode(content)
        let count = max(1, (plaintext.count + chunkByteCount - 1) / chunkByteCount)
        let recordID = "v1-\(operationID.uuidString.lowercased())"
        var chunks: [Data] = []
        for index in 0..<count {
            let range = (index * chunkByteCount)..<min(plaintext.count, (index + 1) * chunkByteCount)
            let box = try AES.GCM.seal(plaintext.subdata(in: range), using: derivedKey(key, purpose: "content"),
                authenticating: context(account: account, control: control, recordID: recordID,
                    operationID: operationID, kind: kind, index: index, count: count))
            guard let combined = box.combined else { throw ClipboardSyncServiceError.corruptData }
            chunks.append(combined)
        }
        return ClipboardSyncUpload(record: ClipboardSyncRemoteRecord(
            recordID: recordID, operationID: operationID, epoch: control.epoch, keyID: control.keyID,
            kind: kind, chunkCount: count, encryptedByteCount: Int64(chunks.reduce(0) { $0 + $1.count }),
            digest: digest(chunks)
        ), chunks: chunks)
    }

    static func open(
        _ record: ClipboardSyncRemoteRecord, chunks: [Data], account: ClipboardSyncAccount,
        control: ClipboardSyncControl, key: Data
    ) throws -> ClipboardSyncContent {
        guard record.epoch == control.epoch, record.keyID == control.keyID,
              record.chunkCount > 0, record.chunkCount == chunks.count,
              record.encryptedByteCount == chunks.reduce(Int64(0), { $0 + Int64($1.count) }),
              record.digest == digest(chunks) else { throw ClipboardSyncServiceError.corruptData }
        var plaintext = Data()
        for (index, chunk) in chunks.enumerated() {
            do {
                plaintext.append(try AES.GCM.open(AES.GCM.SealedBox(combined: chunk),
                    using: derivedKey(key, purpose: "content"),
                    authenticating: context(account: account, control: control, recordID: record.recordID,
                        operationID: record.operationID, kind: record.kind, index: index, count: chunks.count)))
            } catch { throw ClipboardSyncServiceError.corruptData }
        }
        do {
            let content = try JSONDecoder().decode(ClipboardSyncContent.self, from: plaintext)
            switch (record.kind, content) {
            case (.entry, .rejoin), (.tag, .withdrawal), (.entry, .deletion), (.tag, .tag), (.tag, .tagMembership), (.tag, .tagState), (.tag, .tagMerge), (.entry, .text), (.entry, .textEdit), (.entry, .entry), (.entry, .metadata), (.fileBody, .fileBody): return content
            default: throw ClipboardSyncServiceError.corruptData
            }
        } catch { throw ClipboardSyncServiceError.corruptData }
    }

    static func digest(_ chunks: [Data]) -> Data {
        var hasher = SHA256()
        for chunk in chunks { hasher.update(data: chunk) }
        return Data(hasher.finalize())
    }

    private static func derivedKey(_ key: Data, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("dev.bybee.AnyDoor.clipboard-sync.v1".utf8),
            info: Data(purpose.utf8), outputByteCount: 32)
    }

    private static func context(
        account: ClipboardSyncAccount, control: ClipboardSyncControl, recordID: String,
        operationID: UUID, kind: ClipboardSyncRecordKind, index: Int, count: Int
    ) -> Data {
        Data(["v1", account.identifier, control.epoch.uuidString, control.keyID.uuidString,
              recordID, operationID.uuidString, kind.rawValue, String(index), String(count)]
            .joined(separator: ":").utf8)
    }
}
