import Darwin
import Foundation
import GRDB

extension ClipboardHistoryModule {
    public func capture(
        _ request: ClipboardHistoryCaptureRequest
    ) throws -> ClipboardHistoryCaptureOutcome {
        try captureExplicit(request)
    }

    public func page(
        _ query: ClipboardHistoryQuery,
        after cursor: ClipboardHistoryCursor? = nil
    ) throws -> ClipboardHistoryPage {
        try indexedPage(query, after: cursor)
    }

    public func apply(
        _ mutation: ClipboardHistoryMutation
    ) async throws -> ClipboardHistoryMutationOutcome {
        let database = try requiredDatabase()
        switch mutation {
        case .delete(let entryID):
            return try await delete(entryID, from: database)
        case .setFavorite(let entryID, let isFavorite):
            return try setFavorite(
                isFavorite,
                for: entryID,
                in: database
            )
        case .setTags(let entryID, let tagIDs):
            return try setTags(tagIDs, for: entryID, in: database)
        case .editText(let entryID, let text):
            return try await editText(
                text,
                for: entryID,
                in: database
            )
        }
    }

    public func materialize(
        _ request: ClipboardHistoryMaterializationRequest
    ) throws -> ClipboardHistoryMaterialization {
        let database = try requiredDatabase()
        let id = request.entryID.value.uuidString.lowercased()
        guard try database.read({
            try isLiveEntry(id, at: now(), in: $0)
        }) else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        if request.purpose == .preview,
            let row = try database.read({ database in
                try Row.fetchOne(
                    database,
                    sql: """
                        SELECT payload.relative_path
                        FROM clipboard_entries AS entry
                        JOIN clipboard_payloads AS payload
                          ON payload.id = entry.thumbnail_payload_id
                        WHERE entry.id = ?
                        """,
                    arguments: [id]
                )
            })
        {
            let data = try materializePayload(
                path: row["relative_path"],
                kind: .thumbnail,
                entryID: request.entryID
            )
            return ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .data(typeIdentifier: "public.png", data)
                        ]
                    )
                ]
            )
        }

        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT representation.item_index,
                           representation.representation_index,
                           representation.kind,
                           representation.type_identifier,
                           representation.text_value,
                           representation.data_value,
                           payload.relative_path AS payload_path,
                           payload.kind AS payload_kind
                    FROM clipboard_representations AS representation
                    LEFT JOIN clipboard_payloads AS payload
                      ON payload.id = representation.payload_id
                    WHERE representation.entry_id = ?
                    ORDER BY representation.item_index,
                             representation.representation_index
                    """,
                arguments: [id]
            )
        }
        guard !rows.isEmpty else {
            throw ClipboardHistoryModuleError.entryNotFound
        }
        if request.purpose == .plainTextPaste {
            let groupedRows = Dictionary(
                grouping: rows,
                by: { $0["item_index"] as Int }
            )
            var items: [ClipboardHistoryMaterializedItem] = []
            for itemIndex in groupedRows.keys.sorted() {
                guard let exactTextRow = groupedRows[itemIndex]?.first(where: {
                    ($0["type_identifier"] as String)
                        == "public.utf8-plain-text"
                        && ($0["text_value"] as String?) != nil
                }), let value: String = exactTextRow["text_value"]
                else {
                    throw ClipboardHistoryModuleError.operationUnavailable
                }
                items.append(
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(
                                typeIdentifier: "public.utf8-plain-text",
                                value: value
                            )
                        ]
                    )
                )
            }
            return ClipboardHistoryMaterialization(items: items)
        }
        let fileReferences = try materializeFileReferences(
            for: request.entryID,
            from: database
        )

        var materializedItems: [ClipboardHistoryMaterializedItem] = []
        let groupedRows = Dictionary(
            grouping: rows,
            by: { $0["item_index"] as Int }
        )
        for itemIndex in groupedRows.keys.sorted() {
            guard let itemRows = groupedRows[itemIndex] else { continue }
            let representations = try itemRows.map { row in
                if (row["kind"] as String) == "fileReference" {
                    guard let reference = fileReferences[itemIndex] else {
                        throw ClipboardHistoryModuleError.fileReferencesUnavailable(
                            request.entryID,
                            count: 1
                        )
                    }
                    return ClipboardHistoryMaterializedRepresentation.file(
                        reference
                    )
                }
                if let text: String = row["text_value"] {
                    return ClipboardHistoryMaterializedRepresentation.text(
                        typeIdentifier: row["type_identifier"],
                        value: text
                    )
                }
                if let data: Data = row["data_value"] {
                    return .data(
                        typeIdentifier: row["type_identifier"],
                        data
                    )
                }
                guard let path: String = row["payload_path"],
                    let kindValue: String = row["payload_kind"],
                    let kind = ClipboardHistoryPayloadKind(
                        databaseValue: kindValue
                    )
                else {
                    throw ClipboardHistoryModuleError.payloadUnavailable(
                        request.entryID
                    )
                }
                let data = try materializePayload(
                    path: path,
                    kind: kind,
                    entryID: request.entryID
                )
                return .data(typeIdentifier: row["type_identifier"], data)
            }
            materializedItems.append(
                ClipboardHistoryMaterializedItem(
                    representations: representations
                )
            )
        }
        return ClipboardHistoryMaterialization(items: materializedItems)
    }

    private func materializeFileReferences(
        for entryID: ClipboardHistoryEntryID,
        from database: DatabasePool
    ) throws -> [Int: ClipboardHistoryMaterializedFileReference] {
        let storedID = entryID.value.uuidString.lowercased()
        let rows = try database.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT item_index, captured_path, display_name,
                           bookmark_data, identity_data
                    FROM clipboard_file_members
                    WHERE entry_id = ?
                    ORDER BY item_index, member_index
                    """,
                arguments: [storedID]
            )
        }
        guard !rows.isEmpty else { return [:] }

        struct ResolvedFile {
            let itemIndex: Int
            let capturedPath: String
            let displayName: String
            let url: URL
            let bookmark: Data
        }
        var resolved: [ResolvedFile] = []
        var unavailableCount = 0
        for row in rows {
            guard let bookmark: Data = row["bookmark_data"],
                let identityData: Data = row["identity_data"]
            else {
                unavailableCount += 1
                continue
            }
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withoutUI, .withoutMounting],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                let resourceValues = try url.resourceValues(
                    forKeys: [.fileResourceIdentifierKey, .nameKey]
                )
                guard let currentIdentity =
                    resourceValues.fileResourceIdentifier as? NSObject,
                    let capturedIdentity = try NSKeyedUnarchiver
                        .unarchivedObject(
                            ofClasses: [
                                NSObject.self,
                                NSData.self,
                                NSString.self,
                                NSNumber.self,
                            ],
                            from: identityData
                        ) as? NSObject,
                    capturedIdentity.isEqual(currentIdentity)
                else {
                    unavailableCount += 1
                    continue
                }
                let refreshedBookmark: Data
                if isStale {
                    refreshedBookmark = try url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: [
                            .contentTypeKey,
                            .fileResourceIdentifierKey,
                            .nameKey,
                        ],
                        relativeTo: nil
                    )
                } else {
                    refreshedBookmark = bookmark
                }
                resolved.append(
                    ResolvedFile(
                        itemIndex: row["item_index"],
                        capturedPath: row["captured_path"],
                        displayName: resourceValues.name
                            ?? (row["display_name"] as String),
                        url: url,
                        bookmark: refreshedBookmark
                    )
                )
            } catch {
                unavailableCount += 1
            }
        }
        guard unavailableCount == 0 else {
            throw ClipboardHistoryModuleError.fileReferencesUnavailable(
                entryID,
                count: unavailableCount
            )
        }

        try database.write { database in
            for file in resolved {
                try database.execute(
                    sql: """
                        UPDATE clipboard_file_members
                        SET current_path = ?, display_name = ?,
                            bookmark_data = ?, availability = 'available'
                        WHERE entry_id = ? AND item_index = ?
                    """,
                    arguments: [
                        file.url.path,
                        file.displayName,
                        file.bookmark,
                        storedID,
                        file.itemIndex,
                    ]
                )
                for (kind, value) in [
                    ("fileName", file.displayName),
                    ("currentPath", file.url.path),
                ] {
                    try Self.replaceSearchField(
                        entryID: storedID,
                        kind: kind,
                        index: file.itemIndex,
                        value: value,
                        rankingGroup: Self.searchRankingGroup(for: kind),
                        in: database,
                        faultInjector: faultInjector
                    )
                }
            }
            try Self.bumpSearchIndexGeneration(in: database)
        }
        return Dictionary(
            uniqueKeysWithValues: resolved.map { file in
                (
                    file.itemIndex,
                    ClipboardHistoryMaterializedFileReference(
                        capturedPath: file.capturedPath,
                        displayName: file.displayName,
                        currentURL: file.url
                    )
                )
            }
        )
    }

    public func performMaintenance(
        orphanGracePeriod: TimeInterval = 3_600
    ) throws -> ClipboardHistoryMaintenanceReport {
        let database = try requiredDatabase()
        let maintenanceDate = now()
        let referencedPaths = try database.write { database in
            let expiredIDs = try expiredEntryIDs(
                at: maintenanceDate,
                in: database
            )
            _ = try logicallyDelete(
                entryIDs: expiredIDs,
                in: database
            )
            let paths = Set(
                try String.fetchAll(
                    database,
                    sql: """
                        SELECT DISTINCT payload.relative_path
                        FROM clipboard_payloads AS payload
                        WHERE EXISTS (
                            SELECT 1
                            FROM clipboard_representations AS representation
                            WHERE representation.payload_id = payload.id
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM clipboard_entries AS entry
                            WHERE entry.thumbnail_payload_id = payload.id
                        )
                        OR EXISTS (
                            SELECT 1
                            FROM clipboard_file_members AS member
                            WHERE member.payload_id = payload.id
                        )
                        """
                )
            )
            try database.execute(
                sql: """
                    DELETE FROM clipboard_payloads
                    WHERE NOT EXISTS (
                        SELECT 1 FROM clipboard_representations
                        WHERE clipboard_representations.payload_id =
                              clipboard_payloads.id
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM clipboard_entries
                        WHERE clipboard_entries.thumbnail_payload_id =
                              clipboard_payloads.id
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM clipboard_file_members
                        WHERE clipboard_file_members.payload_id =
                              clipboard_payloads.id
                    )
                    """
            )
            return paths
        }
        let reclaimed: Int
        do {
            let boundedGracePeriod = min(
                max(orphanGracePeriod, 0),
                24 * 60 * 60
            )
            reclaimed = try requiredPayloadStore().reconcile(
                referencedPaths: referencedPaths,
                olderThan: maintenanceDate.addingTimeInterval(
                    -boundedGracePeriod
                )
            )
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        try database.writeWithoutTransaction { database in
            try database.execute(sql: "PRAGMA incremental_vacuum")
            try database.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let storageBytes = try storageUsage()
        try database.write { database in
            try Self.recordMaintenanceSuccess(in: database, at: now())
        }
        return ClipboardHistoryMaintenanceReport(
            reclaimedPayloadCount: reclaimed,
            storageBytes: storageBytes
        )
    }

    public func storageUsage() throws -> UInt64 {
        let descriptor = Darwin.open(
            storeRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return 0
            }
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        defer { Darwin.close(descriptor) }
        return try allocatedSize(
            ofDirectoryDescriptor: descriptor,
            representedBy: storeRoot
        )
    }

    func awaitPendingReclamation() async
        -> ClipboardHistoryReclamationReport
    {
        await payloadReclaimer.drain()
    }

    public func reset(
        confirmation: ClipboardHistoryResetConfirmation
    ) async throws {
        switch confirmation {
        case .confirmed:
            break
        }
        guard let keyStore else {
            throw ClipboardHistoryModuleError.resetFailed
        }
        monitoringRequested = false
        monitoringEnabled = false
        await captureMonitor?.setEnabled(false)
        await stopMaintenanceTask()
        _ = await searchIndexRebuildTask?.value
        searchIndexRebuildTask = nil
        try database?.close()
        database = nil
        derivedKeys = nil
        do {
            if FileManager.default.fileExists(atPath: storeRoot.path) {
                try FileManager.default.removeItem(at: storeRoot)
            }
        } catch {
            availability = .unavailable
            availabilityReason = .storeIOFailure
            throw ClipboardHistoryModuleError.resetFailed
        }

        guard keyStore.delete() == .missing else {
            availability = .unavailable
            availabilityReason = .keychainFailure
            throw ClipboardHistoryModuleError.resetFailed
        }
        let resolution = Self.resolveStore(
            at: storeRoot,
            keyStore: keyStore,
            maintenanceDate: now()
        )
        database = resolution.database
        searchIndexRebuildTask = Self.makeSearchIndexRebuildTask(
            for: resolution.database,
            faultInjector: faultInjector
        )
        derivedKeys = resolution.keys
        availability = resolution.availability
        availabilityReason = resolution.reason
        guard availability == .ready else {
            throw ClipboardHistoryModuleError.resetFailed
        }
        startMaintenanceTaskIfNeeded()
    }
}

extension ClipboardHistoryModule {
    func requiredPayloadStore() throws -> ClipboardHistoryPayloadStore {
        guard let payloadKey = derivedKeys?.payloadKey else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return ClipboardHistoryPayloadStore(
            root: storeRoot,
            key: payloadKey,
            faultInjector: faultInjector
        )
    }

    func insertPayload(
        _ payload: ClipboardHistoryPublishedPayload,
        into database: Database,
        at date: Date
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_payloads(
                    id, relative_path, kind, crypto_version,
                    plaintext_byte_count, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                payload.id.uuidString.lowercased(),
                payload.relativePath,
                payload.kind.databaseValue,
                payload.cryptoVersion,
                payload.plaintextByteCount,
                date.timeIntervalSince1970,
            ]
        )
    }

    fileprivate func delete(
        _ entryID: ClipboardHistoryEntryID,
        from database: DatabasePool
    ) async throws -> ClipboardHistoryMutationOutcome {
        let storedID = entryID.value.uuidString.lowercased()
        let date = now()
        let result: EntryDeletionResult
        do {
            result = try await database.write { database in
                guard try isLiveEntry(storedID, at: date, in: database) else {
                    return EntryDeletionResult(
                        didDelete: false,
                        payloadPaths: []
                    )
                }
                let paths = try logicallyDelete(
                    entryIDs: [storedID],
                    in: database
                )
                try faultInjector.check(.databaseTransaction)
                return EntryDeletionResult(
                    didDelete: true,
                    payloadPaths: paths
                )
            }
        } catch let error as ClipboardHistoryModuleError {
            throw error
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        guard result.didDelete else { return .notFound }
        await enqueueReclamation(for: result.payloadPaths)
        return .deleted
    }

    fileprivate func materializePayload(
        path: String,
        kind: ClipboardHistoryPayloadKind,
        entryID: ClipboardHistoryEntryID
    ) throws -> Data {
        do {
            return try requiredPayloadStore().materialize(
                relativePath: path,
                expectedKind: kind
            )
        } catch ClipboardHistoryStorageError.payloadAuthenticationFailed,
            ClipboardHistoryStorageError.invalidPayloadEnvelope,
            ClipboardHistoryStorageError.injected(.payloadAuthentication)
        {
            throw ClipboardHistoryModuleError.payloadAuthenticationFailed(
                entryID
            )
        } catch {
            throw ClipboardHistoryModuleError.payloadUnavailable(entryID)
        }
    }

    func mapStorageError(
        _ error: Error,
        entryID: ClipboardHistoryEntryID
    ) -> ClipboardHistoryModuleError {
        switch error {
        case ClipboardHistoryStorageError.payloadAuthenticationFailed,
            ClipboardHistoryStorageError.invalidPayloadEnvelope,
            ClipboardHistoryStorageError.injected(.payloadAuthentication):
            .payloadAuthenticationFailed(entryID)
        case is ClipboardHistoryStorageError:
            .storageFailure
        default:
            .storageFailure
        }
    }

    fileprivate static func entryID(from row: Row) throws -> ClipboardHistoryEntryID {
        guard let value = UUID(uuidString: row["id"]) else {
            throw ClipboardHistoryModuleError.storeUnavailable
        }
        return ClipboardHistoryEntryID(value)
    }

    fileprivate func allocatedSize(
        ofDirectoryDescriptor directoryDescriptor: Int32,
        representedBy directory: URL
    ) throws -> UInt64 {
        let streamDescriptor = Darwin.dup(directoryDescriptor)
        guard streamDescriptor >= 0 else {
            throw ClipboardHistoryStorageError.fileOperationFailed(errno)
        }
        guard let stream = Darwin.fdopendir(streamDescriptor) else {
            let failure = errno
            Darwin.close(streamDescriptor)
            throw ClipboardHistoryStorageError.fileOperationFailed(failure)
        }
        defer { Darwin.closedir(stream) }

        var total: UInt64 = 0
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 {
                    throw ClipboardHistoryStorageError.fileOperationFailed(
                        errno
                    )
                }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(entry.pointee.d_namlen) + 1
                ) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var observed = stat()
            guard name.withCString({
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &observed,
                    AT_SYMLINK_NOFOLLOW
                )
            }) == 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            let observedKind = observed.st_mode & mode_t(S_IFMT)
            if observedKind == mode_t(S_IFLNK) {
                continue
            }
            guard observedKind == mode_t(S_IFDIR)
                    || observedKind == mode_t(S_IFREG)
            else {
                continue
            }

            let child = directory.appendingPathComponent(name)
            try storageTraversalHook?(child)
            let flags =
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                | (observedKind == mode_t(S_IFDIR) ? O_DIRECTORY : 0)
            let childDescriptor = name.withCString {
                Darwin.openat(directoryDescriptor, $0, flags)
            }
            guard childDescriptor >= 0 else {
                throw ClipboardHistoryStorageError.fileOperationFailed(errno)
            }
            try withClipboardHistoryFileDescriptor(childDescriptor) {
                openedDescriptor in
                var opened = stat()
                guard Darwin.fstat(openedDescriptor, &opened) == 0 else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(
                        errno
                    )
                }
                guard Self.sameFileIdentity(observed, opened) else {
                    throw ClipboardHistoryStorageError.fileOperationFailed(
                        ESTALE
                    )
                }

                if observedKind == mode_t(S_IFDIR) {
                    let childSize = try allocatedSize(
                        ofDirectoryDescriptor: openedDescriptor,
                        representedBy: child
                    )
                    let (sum, overflow) =
                        total.addingReportingOverflow(childSize)
                    guard !overflow else {
                        throw ClipboardHistoryStorageError.fileOperationFailed(
                            EOVERFLOW
                        )
                    }
                    total = sum
                } else {
                    let blocks = max(opened.st_blocks, 0)
                    let (bytes, multiplicationOverflow) =
                        UInt64(blocks).multipliedReportingOverflow(by: 512)
                    let (sum, additionOverflow) =
                        total.addingReportingOverflow(bytes)
                    guard !multiplicationOverflow, !additionOverflow else {
                        throw ClipboardHistoryStorageError.fileOperationFailed(
                            EOVERFLOW
                        )
                    }
                    total = sum
                }
            }
        }
        return total
    }

    private static func sameFileIdentity(
        _ observed: stat,
        _ opened: stat
    ) -> Bool {
        observed.st_dev == opened.st_dev
            && observed.st_ino == opened.st_ino
            && (observed.st_mode & mode_t(S_IFMT))
                == (opened.st_mode & mode_t(S_IFMT))
    }
}

private func withClipboardHistoryFileDescriptor<Result>(
    _ descriptor: Int32,
    _ body: (Int32) throws -> Result
) rethrows -> Result {
    defer { Darwin.close(descriptor) }
    return try body(descriptor)
}

private struct EntryDeletionResult: Sendable {
    let didDelete: Bool
    let payloadPaths: [String]
}

extension ClipboardHistoryPayloadKind {
    fileprivate init?(databaseValue: String) {
        switch databaseValue {
        case "bitmap":
            self = .bitmap
        case "thumbnail":
            self = .thumbnail
        case "legacyOwnedFile":
            self = .legacyOwnedFile
        default:
            return nil
        }
    }
}
