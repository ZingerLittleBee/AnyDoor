import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

extension ClipboardHistoryModule {
    struct ClipboardSyncPublishedBitmap {
        let bitmap: ClipboardHistoryPublishedPayload
        let thumbnail: ClipboardHistoryPublishedPayload
    }

    struct ClipboardSyncPreparedEntry {
        let identity: CanonicalIdentity?
        let bitmaps: [RepresentationPosition: ClipboardSyncPublishedBitmap]
        let thumbnailID: UUID?
    }

    func prepareSyncEntryContent(_ content: ClipboardSyncEntryContent) throws -> ClipboardSyncPreparedEntry {
        let snapshot = try validatedSyncSnapshot(content)
        let identity = try snapshot.map { try CanonicalIdentity(snapshot: $0, fingerprintDigest: fingerprintDigest) }
        let store = try requiredPayloadStore()
        var bitmaps: [RepresentationPosition: ClipboardSyncPublishedBitmap] = [:]
        var thumbnailID: UUID?
        for (itemIndex, item) in content.items.enumerated() {
            for (representationIndex, representation) in item.representations.enumerated() {
                guard case .bitmap(let png, let thumbnail) = representation else { continue }
                let bitmap = try store.publish(png, kind: .bitmap)
                let preview = try store.publish(thumbnail, kind: .thumbnail)
                bitmaps[.init(itemIndex: itemIndex, representationIndex: representationIndex)] = .init(bitmap: bitmap, thumbnail: preview)
                if thumbnailID == nil { thumbnailID = preview.id }
            }
        }
        return .init(identity: identity, bitmaps: bitmaps, thumbnailID: thumbnailID)
    }

    func syncEntryContent(id: UUID, tags: [ClipboardSyncTagContent], account: ClipboardSyncAccount,
                          control: ClipboardSyncControl, key: Data, in database: Database) throws -> ClipboardSyncEntryContent {
        let storedID = id.uuidString.lowercased()
        guard let entry = try Row.fetchOne(database, sql: "SELECT * FROM clipboard_entries WHERE id = ?", arguments: [storedID]) else {
            throw ClipboardSyncServiceError.localStorage
        }
        let itemIndices = try Int.fetchAll(database,
            sql: "SELECT item_index FROM clipboard_items WHERE entry_id = ? ORDER BY item_index", arguments: [storedID])
        var isFirstBitmap = true
        let items = try itemIndices.map { itemIndex in
            let rows = try Row.fetchAll(database, sql: """
                SELECT kind, type_identifier, text_value, data_value, payload_id, representation_index FROM clipboard_representations
                WHERE entry_id = ? AND item_index = ? ORDER BY representation_index
                """, arguments: [storedID, itemIndex])
            return ClipboardSyncItemContent(representations: try rows.map { row in
                switch row["kind"] as String {
                case "text": return .text(typeIdentifier: row["type_identifier"], value: row["text_value"])
                case "richText": return .richText(typeIdentifier: row["type_identifier"], data: row["data_value"])
                case "color":
                    let data: Data = row["data_value"]
                    guard let value = Self.normalizedColor(from: data) else { throw ClipboardSyncServiceError.corruptData }
                    return .color(data: data, normalizedValue: value)
                case "bitmap":
                    guard let path = try String.fetchOne(database,
                        sql: "SELECT relative_path FROM clipboard_payloads WHERE id = ?", arguments: [row["payload_id"] as String]),
                        let thumbnailPath = try String.fetchOne(database, sql: """
                            SELECT payload.relative_path FROM clipboard_payloads AS payload
                            WHERE payload.id = ?
                            """, arguments: [entry["thumbnail_payload_id"] as String?]) else {
                        throw ClipboardSyncServiceError.localStorage
                    }
                    let store = try requiredPayloadStore()
                    let png = try store.materialize(relativePath: path, expectedKind: .bitmap)
                    let thumbnail = isFirstBitmap
                        ? try store.materialize(relativePath: thumbnailPath, expectedKind: .thumbnail)
                        : try Self.canonicalBitmap(from: png).thumbnail
                    isFirstBitmap = false
                    return .bitmap(png: png, thumbnail: thumbnail)
                case "fileReference":
                    return .file(try syncFileDescriptor(entryID: storedID, itemIndex: itemIndex,
                        representationIndex: row["representation_index"], account: account, control: control, key: key, in: database))
                default: throw ClipboardSyncServiceError.unsupportedVersion
                }
            })
        }
        return ClipboardSyncEntryContent(id: id, capturedAt: Date(timeIntervalSince1970: entry["captured_at"]),
            sourceBundleID: entry["source_bundle_id"], sourceDisplayName: entry["source_display_name"],
            sourceProvenance: entry["source_provenance"], favorite: entry["is_favorite"], tags: tags,
            items: items, facets: try String.fetchAll(database,
                sql: "SELECT facet FROM clipboard_entry_facets WHERE entry_id = ? ORDER BY facet", arguments: [storedID]),
            recognition: try syncEntryRecognition(entryID: storedID, in: database))
    }

    func importSyncEntryContent(_ content: ClipboardSyncEntryContent, account: ClipboardSyncAccount,
                                record: ClipboardSyncRemoteRecord, prepared: ClipboardSyncPreparedEntry? = nil, in database: Database) throws {
        let sharedID = content.id.uuidString.lowercased()
        guard try String.fetchOne(database, sql: """
            SELECT local_entry_id FROM clipboard_sync_entries WHERE account_id = ? AND epoch = ? AND shared_id = ?
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID]) == nil else { return }
        let prepared = try prepared ?? prepareSyncEntryContent(content)
        var localID = sharedID
        if try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM clipboard_entries WHERE id = ?)", arguments: [localID]) == true {
            localID = UUID().uuidString.lowercased()
        }
        for tag in content.tags { try importSyncTag(tag, account: account, recordID: record.recordID, in: database) }
        for bitmap in prepared.bitmaps.values {
            try insertPayload(bitmap.bitmap, into: database, at: content.capturedAt)
            try insertPayload(bitmap.thumbnail, into: database, at: content.capturedAt)
        }
        let preview = content.items.flatMap(\.representations).compactMap { representation -> String? in
            if case .text(_, let value) = representation { return value }
            if case .file(let file) = representation { return file.displayName }
            return nil
        }.first.map(Self.boundedPreviewText)
        try database.execute(sql: """
            INSERT INTO clipboard_entries(id, captured_at, last_captured_at, source_bundle_id,
                source_display_name, source_provenance, preview_text, is_favorite, thumbnail_payload_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [localID, content.capturedAt.timeIntervalSince1970, content.capturedAt.timeIntervalSince1970,
                content.sourceBundleID, content.sourceDisplayName, content.sourceProvenance, preview, content.favorite,
                prepared.thumbnailID?.uuidString.lowercased()])
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
                case .bitmap:
                    guard let bitmap = prepared.bitmaps[.init(itemIndex: itemIndex, representationIndex: representationIndex)] else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    try database.execute(sql: """
                        INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, payload_id)
                        VALUES (?, ?, ?, 'bitmap', 'public.png', ?)
                        """, arguments: [localID, itemIndex, representationIndex, bitmap.bitmap.id.uuidString.lowercased()])
                case .color(let data, let normalizedValue):
                    try database.execute(sql: """
                        INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, data_value)
                        VALUES (?, ?, ?, 'color', 'com.apple.cocoa.pasteboard.color', ?)
                        """, arguments: [localID, itemIndex, representationIndex, data])
                    try Self.insertSearchField(value: normalizedValue, kind: "normalizedColor", index: searchIndex,
                        rankingGroup: Self.searchRankingGroup(for: "normalizedColor"), entryID: localID, into: database, faultInjector: faultInjector)
                    searchIndex += 1
                case .file(let descriptor):
                    try database.execute(sql: """
                        INSERT INTO clipboard_representations(entry_id, item_index, representation_index, kind, type_identifier, data_value)
                        VALUES (?, ?, ?, 'fileReference', 'public.file-url', ?)
                        """, arguments: [localID, itemIndex, representationIndex, try JSONEncoder().encode(descriptor)])
                    try importSyncFileDescriptor(descriptor, entryID: localID, itemIndex: itemIndex,
                        representationIndex: representationIndex, account: account, record: record, in: database)
                    try Self.insertSearchField(value: descriptor.displayName, kind: "fileName", index: searchIndex,
                        rankingGroup: Self.searchRankingGroup(for: "fileName"), entryID: localID,
                        into: database, faultInjector: faultInjector)
                    searchIndex += 1
                }
            }
        }
        for facet in Set(content.facets) {
            try database.execute(sql: "INSERT INTO clipboard_entry_facets(entry_id, facet) VALUES (?, ?)", arguments: [localID, facet])
        }
        try database.execute(sql: "INSERT INTO clipboard_retention_state(entry_id, retention_started_at, is_protected) VALUES (?, ?, 1)",
            arguments: [localID, content.capturedAt.timeIntervalSince1970])
        if let identity = prepared.identity {
            try database.execute(sql: """
                INSERT INTO clipboard_duplicate_candidates(fingerprint, entry_id, canonical_byte_count, created_at) VALUES (?, ?, ?, ?)
                """, arguments: [identity.fingerprint, localID, identity.canonicalByteCount, content.capturedAt.timeIntervalSince1970])
        }
        try database.execute(sql: """
            INSERT INTO clipboard_sync_entries(account_id, epoch, shared_id, local_entry_id, record_id, origin)
            VALUES (?, ?, ?, ?, ?, 'remote')
            """, arguments: [account.identifier, record.epoch.uuidString, sharedID, localID, record.recordID])
        try seedSyncMemberships(content.tags, sharedID: sharedID, localID: localID,
            account: account, epoch: record.epoch, in: database)
        try seedSyncEntryMetadata(content, account: account, record: record, in: database)
    }

    func validatedSyncSnapshot(_ content: ClipboardSyncEntryContent) throws -> PasteboardSnapshot? {
        guard !content.items.isEmpty, !content.tags.isEmpty,
              content.capturedAt.timeIntervalSince1970.isFinite,
              ClipboardHistoryCaptureSourceProvenance(rawValue: content.sourceProvenance) != nil,
              content.facets.allSatisfy({ ClipboardHistoryFacet(rawValue: $0) != nil }) else {
            throw ClipboardSyncServiceError.corruptData
        }
        var byteCount = 0
        var pixelCount = 0
        var thumbnailByteCount = 0
        var containsFile = false
        let items = try content.items.map { item in
            guard !item.representations.isEmpty else { throw ClipboardSyncServiceError.corruptData }
            return PasteboardSnapshot.Item(representations: try item.representations.compactMap { representation -> PasteboardSnapshot.Representation? in
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
                case .bitmap(let png, let thumbnail):
                    let pixels = try validateSyncBitmap(png, maximumPixels: PasteboardSnapshot.maximumPixelCount - pixelCount)
                    pixelCount += pixels
                    _ = try validateSyncBitmap(thumbnail, maximumPixels: 512 * 512)
                    guard thumbnail.count <= PasteboardSnapshot.maximumByteCount - thumbnailByteCount else {
                        throw ClipboardSyncServiceError.corruptData
                    }
                    thumbnailByteCount += thumbnail.count
                    bytes = png.count
                    result = .bitmap(png: png, thumbnail: thumbnail, isScreenshot: content.facets.contains("screenshot"))
                case .color(let data, let normalizedValue):
                    guard Self.normalizedColor(from: data) == normalizedValue else { throw ClipboardSyncServiceError.corruptData }
                    let sum = data.count.addingReportingOverflow(normalizedValue.utf8.count)
                    guard !sum.overflow else { throw ClipboardSyncServiceError.corruptData }
                    bytes = sum.partialValue
                    result = .color(data: data, normalizedValue: normalizedValue)
                case .file(let descriptor):
                    guard ClipboardSyncFileIO.validFilename(descriptor.displayName) else { throw ClipboardSyncServiceError.corruptData }
                    containsFile = true
                    return nil
                }
                guard bytes <= PasteboardSnapshot.maximumByteCount - byteCount else { throw ClipboardSyncServiceError.corruptData }
                byteCount += bytes
                return result
            })
        }
        // File identity belongs to the shared descriptor, never a source path
        // or a fabricated bookmark. Shared entry receipts handle redelivery.
        guard !containsFile else { return nil }
        return PasteboardSnapshot(items: items,
            extraFacets: Set(content.facets.compactMap(ClipboardHistoryFacet.init(rawValue:))), allowsTextInference: false)
    }

    private func validateSyncBitmap(_ data: Data, maximumPixels: Int) throws -> Int {
        guard data.count <= PasteboardSnapshot.maximumByteCount,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ClipboardSyncServiceError.corruptData }
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow, product.partialValue <= maximumPixels,
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil else {
            throw ClipboardSyncServiceError.corruptData
        }
        return product.partialValue
    }
}
