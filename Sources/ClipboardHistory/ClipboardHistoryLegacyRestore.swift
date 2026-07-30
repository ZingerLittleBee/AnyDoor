import CryptoKit
import Darwin
import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func legacyFileRestorePlan(
        for entryID: ClipboardHistoryEntryID
    ) throws -> ClipboardHistoryLegacyFileRestorePlan {
        let database = try requiredDatabase()
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT item_index, member_index, display_name,
                           captured_path, reference_provenance
                    FROM clipboard_file_members
                    WHERE entry_id = ?
                    ORDER BY item_index, member_index
                    """,
                arguments: [
                    entryID.value.uuidString.lowercased()
                ]
            )
        }
        guard !rows.isEmpty else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        var ownedMembers:
            [ClipboardHistoryLegacyFileRestoreMember] = []
        var unavailableCount = 0
        for row in rows {
            let provenance: String = row["reference_provenance"]
            if provenance == LegacyFileState.legacyOwned.rawValue {
                let displayName: String = row["display_name"]
                let capturedPath: String = row["captured_path"]
                ownedMembers.append(
                    ClipboardHistoryLegacyFileRestoreMember(
                        id: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: row["item_index"],
                            memberIndex: row["member_index"]
                        ),
                        suggestedName: displayName.isEmpty
                            ? URL(fileURLWithPath: capturedPath)
                                .lastPathComponent
                            : displayName
                    )
                )
            } else if provenance == LegacyFileState.unavailable.rawValue {
                unavailableCount += 1
            }
        }
        return ClipboardHistoryLegacyFileRestorePlan(
            entryID: entryID,
            ownedMembers: ownedMembers,
            unavailableCount: unavailableCount
        )
    }

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
                        member.bookmark_data,
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
                (try? validateAlreadyRestoredDestinations(
                    request.destinations,
                    storedMembers: storedMembers
                )) == true
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
        let preparedOutputs: [PublishedLegacyFileRestore]
        do {
            let prepared = try ownedMembers.map { member in
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
            let destinations = try securedLegacyRestoreDestinations(prepared)
            try faultInjector.check(.legacyRestoreBeforePublication)
            let outputs = try destinations.map {
                try publishLegacyRestoreFile($0)
            }
            try validateDistinctLegacyRestoreOutputs(outputs)
            for output in outputs {
                try faultInjector.check(.legacyRestoreFileDurability)
                try output.synchronizeFile()
            }
            var synchronizedDirectories: Set<LegacyRestoreFileIdentity> = []
            for output in outputs
            where synchronizedDirectories.insert(
                output.destination.directory.identity
            ).inserted {
                try faultInjector.check(.legacyRestoreDirectoryDurability)
                try output.destination.directory.synchronize()
            }
            try faultInjector.check(.legacyRestoreBeforeFinalValidation)
            try validateLegacyRestoreOutputs(outputs)
            preparedOutputs = outputs
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }

        let resolved: [ResolvedLegacyFileRestore]
        do {
            resolved = try preparedOutputs.map { output in
                let reference = try legacyFileReference(
                    at: output.destination.requestedURL
                )
                guard reference.isRegularFile,
                    try legacyRestoreFileIdentity(
                        at: reference.url
                    ) == output.identity
                else {
                    throw ClipboardHistoryModuleError
                        .legacyFileRestoreCollision(
                            output.destination.prepared.destination.url
                        )
                }
                try output.validate()
                return ResolvedLegacyFileRestore(
                    output: output,
                    reference: reference
                )
            }
            try validateLegacyRestoreOutputs(preparedOutputs)
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }

        let retiredPayloadPaths: [String]
        do {
            retiredPayloadPaths = try await database.write { database in
                try validateLegacyRestoreOutputs(preparedOutputs)
                var payloadPaths: [String] = []
                for restored in resolved {
                    let member = restored.output.destination.prepared.member
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
                try validateLegacyRestoreOutputs(preparedOutputs)
                return payloadPaths
            }
        } catch {
            throw ClipboardHistoryModuleError.legacyFileRestoreFailed
        }
        await enqueueReclamation(for: retiredPayloadPaths)
        return .restored(memberCount: resolved.count)
    }

    private func validateAlreadyRestoredDestinations(
        _ destinations: [ClipboardHistoryLegacyFileDestination],
        storedMembers: [LegacyStoredFileMember]
    ) throws -> Bool {
        var destinationIdentities: Set<LegacyRestoreFileIdentity> = []
        for destination in destinations {
            guard
                destination.collisionPolicy == .reuseIfIdentical,
                let member = storedMembers.first(where: {
                    $0.id == destination.memberID
                }),
                member.provenance == LegacyFileState.ordinary.rawValue,
                let currentPath = member.currentPath,
                let bookmark = member.bookmark
            else {
                return false
            }
            var isStale = false
            let bookmarkedURL = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            guard !isStale else { return false }
            let storedIdentity = try legacyRestoreFileIdentity(
                at: bookmarkedURL
            )
            let currentIdentity = try legacyRestoreFileIdentity(
                at: URL(fileURLWithPath: currentPath)
            )
            let requestedIdentity = try legacyRestoreFileIdentity(
                at: destination.url
            )
            guard storedIdentity == currentIdentity,
                currentIdentity == requestedIdentity,
                destinationIdentities.insert(requestedIdentity).inserted
            else {
                return false
            }
        }
        return true
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

}

private struct LegacyStoredFileMember: Sendable {
    let id: ClipboardHistoryLegacyFileMemberID
    let currentPath: String?
    let provenance: String
    let bookmark: Data?
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
        bookmark = row["bookmark_data"]
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
    let output: PublishedLegacyFileRestore
    let reference: LegacyResolvedFileReference
}

private struct SecuredLegacyRestoreDestination: Sendable {
    let prepared: PreparedLegacyFileRestore
    let directory: LegacyRestoreDirectory
    let filename: String

    var requestedURL: URL {
        prepared.destination.url.standardizedFileURL
    }

    var canonicalURL: URL {
        directory.canonicalURL.appendingPathComponent(filename)
    }
}

private struct LegacyRestoreDestinationIdentity: Hashable {
    let directory: LegacyRestoreFileIdentity
    let filename: String
}

private struct LegacyRestoreFileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
    }
}

private final class LegacyRestoreDirectory: @unchecked Sendable {
    let fileDescriptor: Int32
    let canonicalURL: URL
    let identity: LegacyRestoreFileIdentity

    init(url: URL) throws {
        canonicalURL = try canonicalLegacyRestoreDirectoryURL(url)
        let descriptor = canonicalURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        do {
            let descriptorStatus = try legacyRestoreStatus(
                fileDescriptor: descriptor,
                requiring: S_IFDIR
            )
            let pathStatus = try legacyRestoreStatus(
                at: canonicalURL,
                requiring: S_IFDIR
            )
            guard
                LegacyRestoreFileIdentity(descriptorStatus)
                    == LegacyRestoreFileIdentity(pathStatus)
            else {
                throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
            }
            fileDescriptor = descriptor
            identity = LegacyRestoreFileIdentity(descriptorStatus)
        } catch {
            close(descriptor)
            throw error
        }
    }

    deinit {
        close(fileDescriptor)
    }

    func validate() throws {
        let descriptorStatus = try legacyRestoreStatus(
            fileDescriptor: fileDescriptor,
            requiring: S_IFDIR
        )
        let pathStatus = try legacyRestoreStatus(
            at: canonicalURL,
            requiring: S_IFDIR
        )
        guard LegacyRestoreFileIdentity(descriptorStatus) == identity,
            LegacyRestoreFileIdentity(pathStatus) == identity
        else {
            throw ClipboardHistoryStorageError.fileOperationFailed(ESTALE)
        }
    }

    func synchronize() throws {
        guard fsync(fileDescriptor) == 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }
}

private final class PublishedLegacyFileRestore: @unchecked Sendable {
    let destination: SecuredLegacyRestoreDestination
    let fileDescriptor: Int32
    let identity: LegacyRestoreFileIdentity

    init(
        destination: SecuredLegacyRestoreDestination,
        fileDescriptor: Int32
    ) throws {
        self.destination = destination
        self.fileDescriptor = fileDescriptor
        let status = try legacyRestoreStatus(
            fileDescriptor: fileDescriptor,
            requiring: S_IFREG
        )
        identity = LegacyRestoreFileIdentity(status)
    }

    deinit {
        close(fileDescriptor)
    }

    func synchronizeFile() throws {
        if fcntl(fileDescriptor, F_FULLFSYNC) != 0,
            fsync(fileDescriptor) != 0
        {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
    }

    func validate() throws {
        try destination.directory.validate()
        let descriptorStatus = try legacyRestoreStatus(
            fileDescriptor: fileDescriptor,
            requiring: S_IFREG
        )
        var destinationStatus = stat()
        let destinationResult = destination.filename.withCString {
            fstatat(
                destination.directory.fileDescriptor,
                $0,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard destinationResult == 0,
            legacyRestoreFileType(destinationStatus) == S_IFREG,
            LegacyRestoreFileIdentity(descriptorStatus) == identity,
            LegacyRestoreFileIdentity(destinationStatus) == identity,
            descriptorStatus.st_size
                == off_t(destination.prepared.proof.byteCount),
            destinationStatus.st_size
                == off_t(destination.prepared.proof.byteCount),
            try legacyRestoreFileIdentity(
                at: destination.canonicalURL
            ) == identity,
            try legacyRestoreFileIdentity(
                at: destination.requestedURL
            ) == identity,
            try streamedLegacyRestoreProof(fileDescriptor)
                == destination.prepared.proof
        else {
            throw ClipboardHistoryModuleError.legacyFileRestoreCollision(
                destination.prepared.destination.url
            )
        }
    }
}

private func securedLegacyRestoreDestinations(
    _ values: [PreparedLegacyFileRestore]
) throws -> [SecuredLegacyRestoreDestination] {
    var identities: Set<LegacyRestoreDestinationIdentity> = []
    return try values.map { value in
        let url = value.destination.url.standardizedFileURL
        let filename = url.lastPathComponent
        guard url.isFileURL,
            url.path.hasPrefix("/"),
            !filename.isEmpty,
            filename != ".",
            filename != ".."
        else {
            throw ClipboardHistoryModuleError.invalidLegacyFileRestore
        }
        let directory = try LegacyRestoreDirectory(
            url: url.deletingLastPathComponent()
        )
        let identity = LegacyRestoreDestinationIdentity(
            directory: directory.identity,
            filename: filename
        )
        guard identities.insert(identity).inserted else {
            throw ClipboardHistoryModuleError.invalidLegacyFileRestore
        }
        return SecuredLegacyRestoreDestination(
            prepared: value,
            directory: directory,
            filename: filename
        )
    }
}

private func publishLegacyRestoreFile(
    _ destination: SecuredLegacyRestoreDestination
) throws -> PublishedLegacyFileRestore {
    let createdDescriptor = destination.filename.withCString {
        openat(
            destination.directory.fileDescriptor,
            $0,
            O_CREAT | O_EXCL | O_NOFOLLOW | O_RDWR | O_CLOEXEC,
            mode_t(0o600)
        )
    }
    if createdDescriptor >= 0 {
        do {
            try writeLegacyRestoreData(
                destination.prepared.data,
                to: createdDescriptor
            )
        } catch {
            close(createdDescriptor)
            throw error
        }
        let output: PublishedLegacyFileRestore
        do {
            output = try PublishedLegacyFileRestore(
                destination: destination,
                fileDescriptor: createdDescriptor
            )
        } catch {
            close(createdDescriptor)
            throw error
        }
        try output.validate()
        return output
    }

    let creationError = errno
    guard creationError == EEXIST,
        destination.prepared.destination.collisionPolicy
            == .reuseIfIdentical
    else {
        if creationError == EEXIST || creationError == ELOOP {
            throw ClipboardHistoryModuleError.legacyFileRestoreCollision(
                destination.prepared.destination.url
            )
        }
        throw ClipboardHistoryStorageError.fileOperationFailed(creationError)
    }

    let existingDescriptor = destination.filename.withCString {
        openat(
            destination.directory.fileDescriptor,
            $0,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
    }
    guard existingDescriptor >= 0 else {
        throw ClipboardHistoryModuleError.legacyFileRestoreCollision(
            destination.prepared.destination.url
        )
    }
    let output: PublishedLegacyFileRestore
    do {
        output = try PublishedLegacyFileRestore(
            destination: destination,
            fileDescriptor: existingDescriptor
        )
    } catch {
        close(existingDescriptor)
        throw ClipboardHistoryModuleError.legacyFileRestoreCollision(
            destination.prepared.destination.url
        )
    }
    try output.validate()
    return output
}

private func validateDistinctLegacyRestoreOutputs(
    _ outputs: [PublishedLegacyFileRestore]
) throws {
    var identities: Set<LegacyRestoreFileIdentity> = []
    for output in outputs {
        try output.validate()
        guard identities.insert(output.identity).inserted else {
            throw ClipboardHistoryModuleError.invalidLegacyFileRestore
        }
    }
}

private func validateLegacyRestoreOutputs(
    _ outputs: [PublishedLegacyFileRestore]
) throws {
    try validateDistinctLegacyRestoreOutputs(outputs)
}

private func canonicalLegacyRestoreDirectoryURL(_ url: URL) throws -> URL {
    let resolved = url.path.withCString { realpath($0, nil) }
    guard let resolved else {
        throw ClipboardHistoryStorageError.fileOperationFailed(errno)
    }
    defer { free(resolved) }
    return URL(
        fileURLWithPath: String(cString: resolved),
        isDirectory: true
    )
}

private func legacyRestoreStatus(
    fileDescriptor: Int32,
    requiring fileType: mode_t
) throws -> stat {
    var status = stat()
    guard fstat(fileDescriptor, &status) == 0 else {
        throw ClipboardHistoryStorageError.fileOperationFailed(errno)
    }
    guard legacyRestoreFileType(status) == fileType else {
        throw ClipboardHistoryStorageError.fileOperationFailed(EFTYPE)
    }
    return status
}

private func legacyRestoreStatus(
    at url: URL,
    requiring fileType: mode_t
) throws -> stat {
    var status = stat()
    let result = url.path.withCString { lstat($0, &status) }
    guard result == 0 else {
        throw ClipboardHistoryStorageError.fileOperationFailed(errno)
    }
    guard legacyRestoreFileType(status) == fileType else {
        throw ClipboardHistoryStorageError.fileOperationFailed(EFTYPE)
    }
    return status
}

private func legacyRestoreFileType(_ status: stat) -> mode_t {
    status.st_mode & mode_t(S_IFMT)
}

private func legacyRestoreFileIdentity(
    at url: URL
) throws -> LegacyRestoreFileIdentity {
    LegacyRestoreFileIdentity(
        try legacyRestoreStatus(at: url, requiring: S_IFREG)
    )
}

private func streamedLegacyRestoreProof(
    _ fileDescriptor: Int32
) throws -> StreamedFileProof {
    var hasher = SHA256()
    var byteCount = 0
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
        let readCount = buffer.withUnsafeMutableBytes { bytes in
            pread(
                fileDescriptor,
                bytes.baseAddress,
                bytes.count,
                offset
            )
        }
        if readCount == 0 {
            break
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        let count = Int(readCount)
        let chunk = Data(buffer[..<count])
        hasher.update(data: chunk)
        byteCount += count
        offset += off_t(count)
    }
    return StreamedFileProof(
        byteCount: byteCount,
        sha256: Data(hasher.finalize())
    )
}

private func writeLegacyRestoreData(
    _ data: Data,
    to fileDescriptor: Int32
) throws {
    try data.withUnsafeBytes { bytes in
        var written = 0
        while written < bytes.count {
            let result = write(
                fileDescriptor,
                bytes.baseAddress?.advanced(by: written),
                bytes.count - written
            )
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            guard result > 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(EIO)
            }
            written += result
        }
    }
}
