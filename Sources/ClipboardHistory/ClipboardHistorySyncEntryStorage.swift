import Foundation
import GRDB

extension ClipboardHistoryModule {
    func syncEntryContent(id: UUID, tags: [ClipboardSyncTagContent], in database: Database) throws -> ClipboardSyncEntryContent {
        let storedID = id.uuidString.lowercased()
        guard let entry = try Row.fetchOne(database, sql: "SELECT * FROM clipboard_entries WHERE id = ?", arguments: [storedID]) else {
            throw ClipboardSyncServiceError.localStorage
        }
        let itemIndices = try Int.fetchAll(database,
            sql: "SELECT item_index FROM clipboard_items WHERE entry_id = ? ORDER BY item_index", arguments: [storedID])
        let items = try itemIndices.map { itemIndex in
            let rows = try Row.fetchAll(database, sql: """
                SELECT kind, type_identifier, text_value, data_value FROM clipboard_representations
                WHERE entry_id = ? AND item_index = ? ORDER BY representation_index
                """, arguments: [storedID, itemIndex])
            return ClipboardSyncItemContent(representations: try rows.map { row in
                switch row["kind"] as String {
                case "text": return .text(typeIdentifier: row["type_identifier"], value: row["text_value"])
                case "richText": return .richText(typeIdentifier: row["type_identifier"], data: row["data_value"])
                default: throw ClipboardSyncServiceError.unsupportedVersion
                }
            })
        }
        return ClipboardSyncEntryContent(id: id, capturedAt: Date(timeIntervalSince1970: entry["captured_at"]),
            sourceBundleID: entry["source_bundle_id"], sourceDisplayName: entry["source_display_name"],
            sourceProvenance: entry["source_provenance"], favorite: entry["is_favorite"], tags: tags,
            items: items, facets: try String.fetchAll(database,
                sql: "SELECT facet FROM clipboard_entry_facets WHERE entry_id = ? ORDER BY facet", arguments: [storedID]),
            recognition: .init())
    }

    func importSyncEntryContent(_ content: ClipboardSyncEntryContent, account: ClipboardSyncAccount,
                                record: ClipboardSyncRemoteRecord, in database: Database) throws {
        let sharedID = content.id.uuidString.lowercased()
        guard try String.fetchOne(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID]) == nil else { return }
        let snapshot = try validatedSyncSnapshot(content)
        let identity = try CanonicalIdentity(snapshot: snapshot, fingerprintDigest: fingerprintDigest)
        var localID = sharedID
        if try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_entries WHERE id = ?)", arguments: [localID]) == true {
            localID = UUID().uuidString.lowercased()
        }
        for tag in content.tags { try importSyncTag(tag, account: account, recordID: record.recordID, in: database) }
        let preview = content.items.flatMap(\.representations).compactMap { representation -> String? in
            if case .text(_, let value) = representation { return value }
            return nil
        }.first.map(Self.boundedPreviewText)
        try database.execute(sql: """
            INSERT INTO clipboard_entries(id, captured_at, last_captured_at, source_bundle_id,
                source_display_name, source_provenance, preview_text, is_favorite)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [localID, content.capturedAt.timeIntervalSince1970, content.capturedAt.timeIntervalSince1970,
                content.sourceBundleID, content.sourceDisplayName, content.sourceProvenance, preview, content.favorite])
        var searchIndex = 0
        for (itemIndex, item) in content.items.enumerated() {
            try database.execute(sql: "INSERT INTO clipboard_items(entry_id, item_index) VALUES (?, ?)", arguments: [localID, itemIndex])
            for (representationIndex, representation) in item.representations.enumerated() {
                switch representation {
                case .text(let typeIdentifier, let value):
                    try database.execute(sql: """
                        INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, text_value)
                        VALUES (?, ?, ?, 'text', ?, ?)
                        """, arguments: [localID, itemIndex, representationIndex, typeIdentifier, value])
                    let kind = typeIdentifier == "public.url" ? "url" : "exactText"
                    try Self.insertSearchField(value: value, kind: kind, index: searchIndex,
                        rankingGroup: Self.searchRankingGroup(for: kind), entryID: localID, into: database, faultInjector: faultInjector)
                    searchIndex += 1
                case .richText(let typeIdentifier, let data):
                    try database.execute(sql: """
                        INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, data_value)
                        VALUES (?, ?, ?, 'richText', ?, ?)
                        """, arguments: [localID, itemIndex, representationIndex, typeIdentifier, data])
                    if let text = Self.derivedRichText(from: data, typeIdentifier: typeIdentifier), !text.isEmpty {
                        try Self.insertSearchField(value: text, kind: "richText", index: searchIndex,
                            rankingGroup: Self.searchRankingGroup(for: "richText"), entryID: localID, into: database, faultInjector: faultInjector)
                        searchIndex += 1
                    }
                case .bitmap, .color, .file: throw ClipboardSyncServiceError.unsupportedVersion
                }
            }
        }
        for facet in Set(content.facets) {
            try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, ?)", arguments: [localID, facet])
        }
        for tag in content.tags {
            try database.execute(sql: "INSERT INTO clipboard_entry_tags(entry_id, tag_id) VALUES (?, ?)", arguments: [localID, tag.id])
        }
        try database.execute(sql: "INSERT INTO clipboard_retention_state(entry_id, retention_started_at, is_protected) VALUES (?, ?, 1)",
            arguments: [localID, content.capturedAt.timeIntervalSince1970])
        try database.execute(sql: """
            INSERT INTO clipboard_duplicate_candidates(fingerprint, entry_id, canonical_byte_count, created_at) VALUES (?, ?, ?, ?)
            """, arguments: [identity.fingerprint, localID, identity.canonicalByteCount, content.capturedAt.timeIntervalSince1970])
        try database.execute(sql: """
            INSERT INTO clipboard_sync_entries(account_id, epoch, shared_id, local_entry_id, record_id, origin)
            VALUES (?, ?, ?, ?, ?, 'remote')
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID, localID, record.recordID])
    }

    func validatedSyncSnapshot(_ content: ClipboardSyncEntryContent) throws -> PasteboardSnapshot {
        guard !content.items.isEmpty, !content.tags.isEmpty,
              content.capturedAt.timeIntervalSince1970.isFinite,
              ClipboardHistoryCaptureSourceProvenance(rawValue: content.sourceProvenance) != nil,
              content.facets.allSatisfy({ ClipboardHistoryFacet(rawValue: $0) != nil }) else {
            throw ClipboardSyncServiceError.corruptData
        }
        var byteCount = 0
        let items = try content.items.map { item in
            guard !item.representations.isEmpty else { throw ClipboardSyncServiceError.corruptData }
            return PasteboardSnapshot.Item(representations: try item.representations.map { representation in
                let result: PasteboardSnapshot.Representation
                let bytes: Int
                switch representation {
                case .text(let typeIdentifier, let value):
                    guard ["public.utf8-plain-text", "public.url"].contains(typeIdentifier) else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    bytes = value.utf8.count
                    result = .text(typeIdentifier: typeIdentifier, value: value)
                case .richText(let typeIdentifier, let data):
                    guard ["public.rtf", "com.apple.flat-rtfd", "public.html"].contains(typeIdentifier) else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    bytes = data.count
                    result = .data(typeIdentifier: typeIdentifier, value: data)
                case .bitmap, .color, .file: throw ClipboardSyncServiceError.unsupportedVersion
                }
                guard bytes <= PasteboardSnapshot.maximumByteCount - byteCount else { throw ClipboardSyncServiceError.corruptData }
                byteCount += bytes
                return result
            })
        }
        return PasteboardSnapshot(items: items,
            extraFacets: Set(content.facets.compactMap(ClipboardHistoryFacet.init(rawValue:))), allowsTextInference: false)
    }
}
