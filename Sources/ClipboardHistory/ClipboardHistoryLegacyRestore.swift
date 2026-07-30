import CryptoKit
import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func restoreLegacyOwnedFiles(
        _ request: ClipboardHistoryLegacyFileRestoreRequest
    ) async throws -> ClipboardHistoryLegacyFileRestoreOutcome {
        let database = try requiredDatabase()
        let entryID = request.entryID.value.uuidString.lowercased()
        let storedMembers = try await database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        member.item_index,
                        member.member_index,
                        member.current_path,
                        member.reference_provenance,
                        member.payload_id,
                        payload.relative_path AS payload_path,
                        payload.kind AS payload_kind
                    FROM clipboard_file_members member
                    LEFT JOIN clipboard_payloads payload
                        ON payload.id = member.payload_id
                    WHERE member.entry_id = ?
                    ORDER BY member.item_index, member.member_index
                    """,
                arguments: [entryID]
            ).map(LegacyStoredFileMember.init(row:))
        }
        guard !storedMembers.isEmpty else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        let destinations = try legacyRestoreDestinations(
            request.destinations
        )
        let ownedMembers = storedMembers.filter {
            $0.provenance == LegacyFileState.legacyOwned.rawValue
        }
        if ownedMembers.isEmpty {
            guard
                request.destinations.count == destinations.count,
                request.destinations.count > 0,
                request.destinations.allSatisfy({ destination in
                    guard
                        destination.collisionPolicy == .reuseIfIdentical,
                        let member = storedMembers.first(where: {
                            $0.id == destination.memberID
                        }),
                        member.provenance == LegacyFileState.ordinary.rawValue,
                        let currentPath = member.currentPath
                    else {
                        return false
                    }
                    return URL(fileURLWithPath: currentPath)
                        .resolvingSymlinksInPath()
                        == destination.url.resolvingSymlinksInPath()
                })
            else {
                throw ClipboardHistoryModuleError.invalidLegacyFileRestore
            }
            return .alreadyRestored(memberCount: request.destinations.count)
        }
        guard
            destinations.count == ownedMembers.count,
            Set(ownedMembers.map(\.id)) == Set(destinations.keys)
        else {
            throw ClipboardHistoryModuleError.invalidLegacyFileRestore
        }

        let payloadStore = try requiredPayloadStore()
        let prepared: [PreparedLegacyFileRestore]
        do {
            prepared = try ownedMembers.map { member in
                guard
                    let payloadPath = member.payloadPath,
                    let payloadKind = member.payloadKind,
                    let kind = ClipboardHistoryPayloadKind(
                        databaseValue: payloadKind
                    ),
                    kind == .legacyOwnedFile,
                    let destination = destinations[member.id]
                else {
                    throw ClipboardHistoryModuleError
                        .invalidLegacyFileRestore
                }
                let data = try payloadStore.materialize(
                    relativePath: payloadPath,
                    expectedKind: kind
                )
                return PreparedLegacyFileRestore(
                    member: member,
                    destination: destination,
                    data: data,
                    proof: StreamedFileProof(
                        byteCount: data.count,
                        sha256: Data(SHA256.hash(data: data))
                    )
                )
            }
            try validateLegacyRestoreDestinations(prepared)
            try publishLegacyRestoreFiles(prepared)
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }

        let resolved: [ResolvedLegacyFileRestore]
        do {
            resolved = try prepared.map {
                ResolvedLegacyFileRestore(
                    prepared: $0,
                    reference: try legacyFileReference(
                        at: $0.destination.url
                    )
                )
            }
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }

        let retiredPayloadPaths: [String]
        do {
            retiredPayloadPaths = try await database.write { database in
                var payloadPaths: [String] = []
                for restored in resolved {
                    let member = restored.prepared.member
                    guard
                        try String.fetchOne(
                            database,
                            sql: """
                                SELECT reference_provenance
                                FROM clipboard_file_members
                                WHERE entry_id = ?
                                  AND item_index = ?
                                  AND member_index = ?
                                  AND payload_id = ?
                                """,
                            arguments: [
                                entryID,
                                member.id.itemIndex,
                                member.id.memberIndex,
                                member.payloadID,
                            ]
                        ) == LegacyFileState.legacyOwned.rawValue
                    else {
                        throw ClipboardHistoryModuleError
                            .invalidLegacyFileRestore
                    }
                    try database.execute(
                        sql: """
                            UPDATE clipboard_file_members
                            SET current_path = ?, display_name = ?,
                                bookmark_data = ?, identity_data = ?,
                                resource_type = ?, availability = 'available',
                                payload_id = NULL,
                                reference_provenance = 'ordinary'
                            WHERE entry_id = ?
                              AND item_index = ?
                              AND member_index = ?
                            """,
                        arguments: [
                            restored.reference.url.path,
                            restored.reference.url.lastPathComponent,
                            restored.reference.bookmark,
                            restored.reference.identity,
                            restored.reference.resourceType,
                            entryID,
                            member.id.itemIndex,
                            member.id.memberIndex,
                        ]
                    )
                    try database.execute(
                        sql: """
                            UPDATE clipboard_legacy_cleanup
                            SET proof_kind = 'equalCurrent',
                                current_path = ?,
                                payload_id = NULL
                            WHERE payload_id = ?
                            """,
                        arguments: [
                            restored.reference.url.path,
                            member.payloadID,
                        ]
                    )
                    for (kind, value) in [
                        (
                            "fileName",
                            restored.reference.url.lastPathComponent
                        ),
                        ("currentPath", restored.reference.url.path),
                    ] {
                        try Self.replaceSearchField(
                            entryID: entryID,
                            kind: kind,
                            index: member.id.itemIndex,
                            value: value,
                            rankingGroup: Self.searchRankingGroup(for: kind),
                            in: database,
                            faultInjector: faultInjector
                        )
                    }
                    try database.execute(
                        sql: """
                            DELETE FROM clipboard_payloads
                            WHERE id = ?
                            """,
                        arguments: [member.payloadID]
                    )
                    guard database.changesCount == 1 else {
                        throw ClipboardHistoryModuleError
                            .invalidLegacyFileRestore
                    }
                    if let payloadPath = member.payloadPath {
                        payloadPaths.append(payloadPath)
                    }
                }
                try Self.bumpHistoryRevision(in: database)
                try Self.bumpSearchIndexGeneration(in: database)
                try faultInjector.check(.databaseTransaction)
                return payloadPaths
            }
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }
        await enqueueReclamation(for: retiredPayloadPaths)
        return .restored(memberCount: resolved.count)
    }

    private func legacyRestoreDestinations(
        _ values: [ClipboardHistoryLegacyFileDestination]
    ) throws -> [
        ClipboardHistoryLegacyFileMemberID:
            ClipboardHistoryLegacyFileDestination
    ] {
        guard !values.isEmpty else {
            throw ClipboardHistoryModuleError.invalidLegacyFileRestore
        }
        var destinations:
            [
                ClipboardHistoryLegacyFileMemberID:
                    ClipboardHistoryLegacyFileDestination
            ] = [:]
        var paths: Set<String> = []
        for value in values {
            guard value.url.isFileURL,
                value.memberID.itemIndex >= 0,
                value.memberID.memberIndex >= 0,
                destinations.updateValue(
                    value,
                    forKey: value.memberID
                ) == nil,
                paths.insert(value.url.standardizedFileURL.path).inserted
            else {
                throw ClipboardHistoryModuleError.invalidLegacyFileRestore
            }
        }
        return destinations
    }

    private func validateLegacyRestoreDestinations(
        _ values: [PreparedLegacyFileRestore]
    ) throws {
        for value in values {
            let destination = value.destination.url
            let parentValues = try destination
                .deletingLastPathComponent()
                .resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
            guard parentValues.isDirectory == true else {
                throw ClipboardHistoryModuleError.invalidLegacyFileRestore
            }
            guard FileManager.default.fileExists(atPath: destination.path)
            else {
                continue
            }
            guard value.destination.collisionPolicy == .reuseIfIdentical else {
                throw ClipboardHistoryModuleError
                    .legacyFileRestoreCollision(destination)
            }
            let resourceValues = try destination.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard resourceValues.isRegularFile == true,
                resourceValues.isSymbolicLink != true,
                try streamedFileProof(destination) == value.proof
            else {
                throw ClipboardHistoryModuleError
                    .legacyFileRestoreCollision(destination)
            }
        }
    }

    private func publishLegacyRestoreFiles(
        _ values: [PreparedLegacyFileRestore]
    ) throws {
        for value in values {
            let destination = value.destination.url
            if FileManager.default.fileExists(atPath: destination.path) {
                continue
            }
            do {
                try value.data.write(
                    to: destination,
                    options: .withoutOverwriting
                )
            } catch {
                if value.destination.collisionPolicy == .reuseIfIdentical,
                    FileManager.default.fileExists(
                        atPath: destination.path
                    ),
                    try streamedFileProof(destination) == value.proof
                {
                    continue
                }
                throw ClipboardHistoryModuleError
                    .legacyFileRestoreCollision(destination)
            }
        }
    }
}

private struct LegacyStoredFileMember: Sendable {
    let id: ClipboardHistoryLegacyFileMemberID
    let currentPath: String?
    let provenance: String
    let payloadID: String?
    let payloadPath: String?
    let payloadKind: String?

    init(row: Row) {
        id = ClipboardHistoryLegacyFileMemberID(
            itemIndex: row["item_index"],
            memberIndex: row["member_index"]
        )
        currentPath = row["current_path"]
        provenance = row["reference_provenance"]
        payloadID = row["payload_id"]
        payloadPath = row["payload_path"]
        payloadKind = row["payload_kind"]
    }
}

private struct PreparedLegacyFileRestore: Sendable {
    let member: LegacyStoredFileMember
    let destination: ClipboardHistoryLegacyFileDestination
    let data: Data
    let proof: StreamedFileProof
}

private struct ResolvedLegacyFileRestore: Sendable {
    let prepared: PreparedLegacyFileRestore
    let reference: LegacyResolvedFileReference
}
