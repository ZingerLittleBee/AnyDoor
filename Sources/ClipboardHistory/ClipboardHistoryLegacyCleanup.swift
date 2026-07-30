import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func cleanupLegacyPayloads(
        in payloadDirectory: URL
    ) async throws -> ClipboardHistoryLegacyCleanupReport {
        guard try currentLegacyMigrationReport() != nil else {
            throw ClipboardHistoryModuleError.legacyCleanupFailed
        }
        let database = try requiredDatabase()
        let proofs: [PendingLegacyCleanup]
        do {
            proofs = try await database.read { database in
                try Row.fetchAll(
                    database,
                    sql: """
                        SELECT
                            cleanup.relative_path AS legacy_relative_path,
                            cleanup.proof_kind,
                            cleanup.current_path,
                            cleanup.plaintext_byte_count,
                            cleanup.sha256,
                            payload.relative_path AS payload_relative_path,
                            payload.kind AS payload_kind
                        FROM clipboard_legacy_cleanup cleanup
                        LEFT JOIN clipboard_payloads payload
                            ON payload.id = cleanup.payload_id
                        WHERE cleanup.is_cleaned = 0
                        ORDER BY cleanup.relative_path
                        """
                ).map(PendingLegacyCleanup.init(row:))
            }
        } catch {
            throw ClipboardHistoryModuleError.legacyCleanupFailed
        }

        var removedCount = 0
        var alreadyMissingCount = 0
        for proof in proofs {
            do {
                try validateLegacyPayloadName(proof.relativePath)
                let legacyURL = payloadDirectory.appendingPathComponent(
                    proof.relativePath
                )
                guard FileManager.default.fileExists(atPath: legacyURL.path)
                else {
                    try await markLegacyPayloadCleaned(
                        proof.relativePath,
                        in: database
                    )
                    alreadyMissingCount += 1
                    continue
                }
                let verifiedURL = try safeLegacyPayloadURL(
                    named: proof.relativePath,
                    in: payloadDirectory
                )
                let expectedProof = StreamedFileProof(
                    byteCount: proof.byteCount,
                    sha256: proof.sha256
                )
                guard try streamedFileProof(verifiedURL) == expectedProof
                else {
                    throw ClipboardHistoryModuleError.legacyCleanupFailed
                }
                try verifyLegacyCleanupRetention(
                    proof,
                    expectedProof: expectedProof
                )
                try faultInjector.check(.legacyCleanupBeforeDelete)
                try FileManager.default.removeItem(at: verifiedURL)
                try faultInjector.check(.legacyCleanupAfterDelete)
                try await markLegacyPayloadCleaned(
                    proof.relativePath,
                    in: database
                )
                removedCount += 1
            } catch {
                throw ClipboardHistoryModuleError.legacyCleanupFailed
            }
        }
        let pendingCount: Int
        do {
            pendingCount = try await database.read {
                try Int.fetchOne(
                    $0,
                    sql: """
                        SELECT COUNT(*)
                        FROM clipboard_legacy_cleanup
                        WHERE is_cleaned = 0
                        """
                ) ?? 0
            }
        } catch {
            throw ClipboardHistoryModuleError.legacyCleanupFailed
        }
        return ClipboardHistoryLegacyCleanupReport(
            removedPayloadCount: removedCount,
            alreadyMissingPayloadCount: alreadyMissingCount,
            pendingPayloadCount: pendingCount,
            canDeleteLegacyRows: pendingCount == 0
        )
    }

    private func verifyLegacyCleanupRetention(
        _ proof: PendingLegacyCleanup,
        expectedProof: StreamedFileProof
    ) throws {
        switch proof.kind {
        case .equalCurrent:
            guard let currentPath = proof.currentPath,
                try streamedFileProof(
                    URL(fileURLWithPath: currentPath)
                ) == expectedProof
            else {
                throw ClipboardHistoryModuleError.legacyCleanupFailed
            }
        case .publishedEncrypted:
            break
        case .encryptedPayload:
            guard let relativePath = proof.payloadRelativePath,
                let kindValue = proof.payloadKind,
                let kind = ClipboardHistoryPayloadKind(
                    databaseValue: kindValue
                )
            else {
                throw ClipboardHistoryModuleError.legacyCleanupFailed
            }
            let data = try requiredPayloadStore().materialize(
                relativePath: relativePath,
                expectedKind: kind
            )
            guard data.count == expectedProof.byteCount,
                Data(SHA256.hash(data: data)) == expectedProof.sha256
            else {
                throw ClipboardHistoryModuleError.legacyCleanupFailed
            }
        }
    }

    private func markLegacyPayloadCleaned(
        _ relativePath: String,
        in database: DatabasePool
    ) async throws {
        try await database.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_legacy_cleanup
                    SET is_cleaned = 1
                    WHERE relative_path = ? AND is_cleaned = 0
                    """,
                arguments: [relativePath]
            )
        }
    }
}

private struct PendingLegacyCleanup: Sendable {
    enum Kind: Sendable {
        case equalCurrent
        case encryptedPayload
        case publishedEncrypted
    }

    let relativePath: String
    let kind: Kind
    let currentPath: String?
    let byteCount: Int
    let sha256: Data
    let payloadRelativePath: String?
    let payloadKind: String?

    init(row: Row) throws {
        relativePath = row["legacy_relative_path"]
        switch row["proof_kind"] as String {
        case "equalCurrent":
            kind = .equalCurrent
        case "encryptedPayload":
            kind = .encryptedPayload
        case "publishedEncrypted":
            kind = .publishedEncrypted
        default:
            throw ClipboardHistoryModuleError.legacyCleanupFailed
        }
        currentPath = row["current_path"]
        byteCount = row["plaintext_byte_count"]
        sha256 = row["sha256"]
        payloadRelativePath = row["payload_relative_path"]
        payloadKind = row["payload_kind"]
    }
}
