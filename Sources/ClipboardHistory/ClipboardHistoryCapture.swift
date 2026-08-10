import AppKit
import Darwin
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

public struct ClipboardHistoryPasteboardCaptureRequest: Sendable {
    fileprivate let snapshotRead: ClipboardHistoryModule.PasteboardSnapshotRead

    @MainActor
    public init(pasteboard: NSPasteboard) {
        snapshotRead = ClipboardHistoryModule.readSnapshot(
            from: pasteboard,
            expectedGeneration: nil
        )
    }

    @MainActor
    init(pasteboard: NSPasteboard, expectedGeneration: Int) {
        snapshotRead = ClipboardHistoryModule.readSnapshot(
            from: pasteboard,
            expectedGeneration: expectedGeneration
        )
    }
}

extension ClipboardHistoryModule {
    func captureExplicit(
        _ request: ClipboardHistoryCaptureRequest
    ) throws -> ClipboardHistoryCaptureOutcome {
        let plainTextType = NSPasteboard.PasteboardType.string.rawValue
        let snapshot: PasteboardSnapshot
        let explicitSearchKind: String?
        switch request.content {
        case .text(let value):
            guard !value.isEmpty else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            snapshot = PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: [
                            .text(typeIdentifier: plainTextType, value: value)
                        ]
                    )
                ],
                extraFacets: [],
                allowsTextInference: true
            )
            explicitSearchKind = "exactText"
        case .ocr(let value):
            guard !value.isEmpty else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            snapshot = PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: [
                            .text(typeIdentifier: plainTextType, value: value)
                        ]
                    )
                ],
                extraFacets: [],
                allowsTextInference: false
            )
            explicitSearchKind = "ocr"
        case .color(let value):
            guard !value.isEmpty else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            snapshot = PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: [
                            .text(typeIdentifier: plainTextType, value: value)
                        ]
                    )
                ],
                extraFacets: [.color],
                allowsTextInference: false
            )
            explicitSearchKind = "normalizedColor"
        case .qrCode(let value):
            guard !value.isEmpty else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            snapshot = PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: [
                            .text(typeIdentifier: plainTextType, value: value)
                        ]
                    )
                ],
                extraFacets: [.qrCode],
                allowsTextInference: false
            )
            explicitSearchKind = "qr"
        case .bitmap(let data, let provenance):
            let sourcePixelCount = try Self.imagePixelCount(in: data)
            guard sourcePixelCount <= PasteboardSnapshot.maximumPixelCount else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            let bitmap = try Self.canonicalBitmap(from: data)
            guard bitmap.pixelCount <= PasteboardSnapshot.maximumPixelCount,
                bitmap.png.count <= PasteboardSnapshot.maximumByteCount
            else {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            snapshot = PasteboardSnapshot(
                items: [
                    PasteboardSnapshot.Item(
                        representations: [
                            .bitmap(
                                png: bitmap.png,
                                thumbnail: bitmap.thumbnail,
                                isScreenshot: provenance == .anyDoorScreenshot
                            )
                        ]
                    )
                ],
                extraFacets: [],
                allowsTextInference: false
            )
            explicitSearchKind = nil
        }
        return try persist(
            snapshot,
            source: request.source,
            explicitSearchKind: explicitSearchKind
        )
    }

    public func capture(
        _ request: ClipboardHistoryPasteboardCaptureRequest,
        source: ClipboardHistoryCaptureSource
    ) throws -> ClipboardHistoryPasteboardCaptureOutcome {
        switch request.snapshotRead {
        case .rejected(let rejection):
            return .skipped(rejection)
        case .snapshot(let candidate):
            let snapshot: PasteboardSnapshot
            switch Self.canonicalizedSnapshot(from: candidate) {
            case .rejected(let rejection):
                return .skipped(rejection)
            case .snapshot(let value):
                snapshot = value
            }
            let outcome = try persist(snapshot, source: source)
            return .captured(outcome)
        }
    }

    @MainActor
    fileprivate static func readSnapshot(
        from pasteboard: NSPasteboard,
        expectedGeneration: Int?
    ) -> PasteboardSnapshotRead {
        let initialChangeCount = pasteboard.changeCount
        if let expectedGeneration,
            expectedGeneration != initialChangeCount
        {
            return .rejected(.generationChanged)
        }
        guard let pasteboardItems = pasteboard.pasteboardItems,
            !pasteboardItems.isEmpty
        else {
            return .rejected(.empty)
        }

        // The pasteboard's own type list as well as the per-item lists: a
        // legacy non-UTI type name (`Pasteboard generator type`, written by
        // apps that still call `declareTypes`) is reported verbatim by
        // `NSPasteboard.types` but dynamically UTI-encoded ("dyn.a…") in
        // `NSPasteboardItem.types`, where it would never match a marker.
        let advertisedTypes = Set(pasteboardItems.flatMap(\.types))
            .union(pasteboard.types ?? [])
        if !advertisedTypes.isDisjoint(with: PasteboardSnapshot.exclusionTypes) {
            return .rejected(.excluded)
        }

        var snapshotItems: [PasteboardSnapshotCandidate.Item] = []
        for pasteboardItem in pasteboardItems {
            var representations: [PasteboardSnapshotCandidate.Representation] = []
            if let text = pasteboardItem.string(forType: .string), !text.isEmpty {
                representations.append(
                    .text(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue, value: text)
                )
            }
            for type in PasteboardSnapshot.richTextTypes {
                if let data = pasteboardItem.data(forType: type) {
                    representations.append(
                        .data(typeIdentifier: type.rawValue, value: data)
                    )
                }
            }
            if let colorData = pasteboardItem.data(forType: .color),
                let normalizedValue = Self.normalizedColor(from: colorData)
            {
                representations.append(
                    .color(data: colorData, normalizedValue: normalizedValue)
                )
            }
            let fileURLText = pasteboardItem.string(forType: .fileURL)
                ?? pasteboardItem.string(forType: .URL).flatMap { value in
                    URL(string: value)?.isFileURL == true ? value : nil
                }
            var capturedFileURL = false
            if let fileURLText {
                capturedFileURL = true
                representations.append(.fileURL(fileURLText))
            }
            if !capturedFileURL,
                let url = pasteboardItem.string(forType: .URL),
                !url.isEmpty
            {
                representations.append(
                    .text(typeIdentifier: NSPasteboard.PasteboardType.URL.rawValue, value: url)
                )
            }
            if let imageData = PasteboardSnapshot.imageTypes.lazy.compactMap({
                pasteboardItem.data(forType: $0)
            }).first {
                representations.append(.bitmap(imageData))
            }
            snapshotItems.append(
                PasteboardSnapshotCandidate.Item(
                    representations: representations
                )
            )
        }

        guard pasteboard.changeCount == initialChangeCount else {
            return .rejected(.generationChanged)
        }
        return .snapshot(
            PasteboardSnapshotCandidate(items: snapshotItems)
        )
    }
}

extension ClipboardHistoryModule {
    struct PasteboardSnapshotCandidate: Sendable {
        let items: [Item]

        struct Item: Sendable {
            let representations: [Representation]
        }

        enum Representation: Sendable {
            case text(typeIdentifier: String, value: String)
            case data(typeIdentifier: String, value: Data)
            case color(data: Data, normalizedValue: String)
            case fileURL(String)
            case bitmap(Data)
        }
    }

    struct PasteboardSnapshot: Sendable {
        static let maximumByteCount = 128 * 1_024 * 1_024
        static let maximumPixelCount = 64 * 1_000_000
        static let richTextTypes: [NSPasteboard.PasteboardType] = [
            .rtf,
            NSPasteboard.PasteboardType("com.apple.flat-rtfd"),
            .html,
        ]
        static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        static let exclusionTypes: Set<NSPasteboard.PasteboardType> = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
            NSPasteboard.PasteboardType("com.agilebits.onepassword"),
            NSPasteboard.PasteboardType("net.antelle.keeweb"),
            NSPasteboard.PasteboardType("de.petermaurer.TransientPasteboardType"),
            NSPasteboard.PasteboardType("com.typeit4me.clipping"),
            NSPasteboard.PasteboardType("Pasteboard generator type"),
        ]

        let items: [Item]
        let extraFacets: Set<ClipboardHistoryFacet>
        let allowsTextInference: Bool

        struct Item: Sendable {
            let representations: [Representation]
        }

        enum Representation: Sendable {
            case text(typeIdentifier: String, value: String)
            case data(typeIdentifier: String, value: Data)
            case bitmap(png: Data, thumbnail: Data, isScreenshot: Bool)
            case file(FileReference)
            case color(data: Data, normalizedValue: String)
        }

        struct FileReference: Sendable {
            let capturedPath: String
            let displayName: String
            let bookmark: Data
            let identity: Data
            let resourceType: String?
        }
    }

    fileprivate enum PasteboardSnapshotRead: Sendable {
        case snapshot(PasteboardSnapshotCandidate)
        case rejected(ClipboardHistoryCaptureRejection)
    }

    private enum PasteboardCanonicalizationResult {
        case snapshot(PasteboardSnapshot)
        case rejected(ClipboardHistoryCaptureRejection)
    }

    private static func canonicalizedSnapshot(
        from candidate: PasteboardSnapshotCandidate
    ) -> PasteboardCanonicalizationResult {
        var items: [PasteboardSnapshot.Item] = []
        var byteCount = 0
        var pixelCount = 0

        for candidateItem in candidate.items {
            var representations: [PasteboardSnapshot.Representation] = []
            for representation in candidateItem.representations {
                switch representation {
                case .text(let typeIdentifier, let value):
                    let bytes = value.lengthOfBytes(using: .utf8)
                    guard byteCount <= PasteboardSnapshot.maximumByteCount
                        - bytes
                    else {
                        return .rejected(.contentTooLarge)
                    }
                    byteCount += bytes
                    representations.append(
                        .text(typeIdentifier: typeIdentifier, value: value)
                    )
                case .data(let typeIdentifier, let value):
                    guard byteCount <= PasteboardSnapshot.maximumByteCount
                        - value.count
                    else {
                        return .rejected(.contentTooLarge)
                    }
                    byteCount += value.count
                    representations.append(
                        .data(typeIdentifier: typeIdentifier, value: value)
                    )
                case .color(let data, let normalizedValue):
                    let bytes = data.count
                        + normalizedValue.lengthOfBytes(using: .utf8)
                    guard byteCount <= PasteboardSnapshot.maximumByteCount
                        - bytes
                    else {
                        return .rejected(.contentTooLarge)
                    }
                    byteCount += bytes
                    representations.append(
                        .color(data: data, normalizedValue: normalizedValue)
                    )
                case .fileURL(let value):
                    guard let reference = try? fileReference(from: value) else {
                        return .rejected(.invalidFileReference)
                    }
                    let bytes = reference.bookmark.count
                        + reference.identity.count
                        + reference.capturedPath.lengthOfBytes(using: .utf8)
                        + reference.displayName.lengthOfBytes(using: .utf8)
                    guard byteCount <= PasteboardSnapshot.maximumByteCount
                        - bytes
                    else {
                        return .rejected(.contentTooLarge)
                    }
                    byteCount += bytes
                    representations.append(.file(reference))
                case .bitmap(let data):
                    guard let sourcePixelCount = try? imagePixelCount(in: data)
                    else {
                        continue
                    }
                    guard pixelCount <= PasteboardSnapshot.maximumPixelCount
                        - sourcePixelCount
                    else {
                        return .rejected(.imageTooLarge)
                    }
                    guard let bitmap = try? canonicalBitmap(from: data) else {
                        continue
                    }
                    guard byteCount <= PasteboardSnapshot.maximumByteCount
                        - bitmap.png.count
                    else {
                        return .rejected(.contentTooLarge)
                    }
                    pixelCount += sourcePixelCount
                    byteCount += bitmap.png.count
                    representations.append(
                        .bitmap(
                            png: bitmap.png,
                            thumbnail: bitmap.thumbnail,
                            isScreenshot: false
                        )
                    )
                }
            }
            guard !representations.isEmpty else {
                return .rejected(.unsupportedItem)
            }
            items.append(PasteboardSnapshot.Item(
                representations: representations
            ))
        }

        return .snapshot(
            PasteboardSnapshot(
                items: items,
                extraFacets: [],
                allowsTextInference: true
            )
        )
    }

    fileprivate func persist(
        _ snapshot: PasteboardSnapshot,
        source: ClipboardHistoryCaptureSource,
        explicitSearchKind: String? = nil
    ) throws -> ClipboardHistoryCaptureOutcome {
        let database = try requiredDatabase()
        do {
            try faultInjector.check(.diskFull)
        } catch {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let identity = try CanonicalIdentity(
            snapshot: snapshot,
            fingerprintDigest: fingerprintDigest
        )
        let entryID = ClipboardHistoryEntryID(UUID())
        let capturedAt = now()
        let storedID = entryID.value.uuidString.lowercased()
        let previewText = snapshot.items.lazy
            .flatMap(\.representations)
            .compactMap { representation -> String? in
                switch representation {
                case .text(_, let value):
                    return value
                case .data(let typeIdentifier, let data):
                    return Self.derivedRichText(
                        from: data,
                        typeIdentifier: typeIdentifier
                    )
                case .bitmap, .file, .color:
                    return nil
                }
            }
            .first
            .map(Self.boundedPreviewText)
        let facets = deriveTextFacets(from: snapshot)
        let payloadStore = try requiredPayloadStore()
        if duplicateReuseEnabled,
            let reusedEntryID = try reusableEntry(
                matching: identity,
                source: source,
                capturedAt: capturedAt,
                facets: facets,
                containsBitmap: snapshot.items
                    .flatMap(\.representations)
                    .contains { representation in
                        if case .bitmap = representation {
                            return true
                        }
                        return false
                    },
                refreshOCRBudget: automaticImageTextIndexingEnabled,
                explicitSearchKind: explicitSearchKind,
                database: database,
                payloadStore: payloadStore
            )
        {
            startDerivedJobSchedulerIfNeeded()
            return ClipboardHistoryCaptureOutcome(entryID: reusedEntryID)
        }
        var publishedBitmaps: [
            RepresentationPosition: (
                bitmap: ClipboardHistoryPublishedPayload,
                thumbnail: ClipboardHistoryPublishedPayload
            )
        ] = [:]

        do {
            for (itemIndex, item) in snapshot.items.enumerated() {
                for (representationIndex, representation) in
                    item.representations.enumerated()
                {
                    guard case .bitmap(let png, let thumbnail, _) = representation else {
                        continue
                    }
                    publishedBitmaps[
                        RepresentationPosition(
                            itemIndex: itemIndex,
                            representationIndex: representationIndex
                        )
                    ] = (
                        try payloadStore.publish(png, kind: .bitmap),
                        try payloadStore.publish(thumbnail, kind: .thumbnail)
                    )
                }
            }
        } catch {
            throw mapStorageError(error, entryID: entryID)
        }
        let entryThumbnailID = publishedBitmaps
            .sorted {
                ($0.key.itemIndex, $0.key.representationIndex)
                    < ($1.key.itemIndex, $1.key.representationIndex)
            }
            .first?
            .value.thumbnail.id

        do {
            try database.write { database in
                for payloads in publishedBitmaps.values {
                    try insertPayload(payloads.bitmap, into: database, at: capturedAt)
                    try insertPayload(payloads.thumbnail, into: database, at: capturedAt)
                }
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_entries(
                            id, captured_at, last_captured_at, source_bundle_id,
                            source_display_name, source_provenance, preview_text,
                            thumbnail_payload_id
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        storedID,
                        capturedAt.timeIntervalSince1970,
                        capturedAt.timeIntervalSince1970,
                        source.bundleIdentifier,
                        source.displayName,
                        source.provenance.rawValue,
                        previewText,
                        entryThumbnailID?.uuidString.lowercased(),
                    ]
                )
                var searchFieldIndex = 0
                for (itemIndex, item) in snapshot.items.enumerated() {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_items(entry_id, item_index)
                            VALUES (?, ?)
                            """,
                        arguments: [storedID, itemIndex]
                    )
                    for (representationIndex, representation) in
                        item.representations.enumerated()
                    {
                        switch representation {
                        case .text(let typeIdentifier, let value):
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_representations(
                                        entry_id, item_index, representation_index,
                                        kind, type_identifier, text_value
                                    ) VALUES (?, ?, ?, 'text', ?, ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    representationIndex,
                                    typeIdentifier,
                                    value,
                                ]
                            )
                            try insertSearchField(
                                value,
                                kind: explicitSearchKind
                                    ?? (
                                        typeIdentifier
                                            == NSPasteboard.PasteboardType.URL.rawValue
                                        ? "url"
                                        : "exactText"
                                    ),
                                index: searchFieldIndex,
                                entryID: storedID,
                                into: database
                            )
                            searchFieldIndex += 1
                        case .data(let typeIdentifier, let value):
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_representations(
                                        entry_id, item_index, representation_index,
                                        kind, type_identifier, data_value
                                    ) VALUES (?, ?, ?, 'richText', ?, ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    representationIndex,
                                    typeIdentifier,
                                    value,
                                ]
                            )
                            if let derivedText = Self.derivedRichText(
                                from: value,
                                typeIdentifier: typeIdentifier
                            ), !derivedText.isEmpty {
                                try insertSearchField(
                                    derivedText,
                                    kind: "richText",
                                    index: searchFieldIndex,
                                    entryID: storedID,
                                    into: database
                                )
                                searchFieldIndex += 1
                            }
                        case .bitmap:
                            let position = RepresentationPosition(
                                itemIndex: itemIndex,
                                representationIndex: representationIndex
                            )
                            guard let payload = publishedBitmaps[position]?.bitmap else {
                                throw ClipboardHistoryModuleError.storageFailure
                            }
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_representations(
                                        entry_id, item_index, representation_index,
                                        kind, type_identifier, payload_id
                                    ) VALUES (?, ?, ?, 'bitmap', ?, ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    representationIndex,
                                    UTType.png.identifier,
                                    payload.id.uuidString.lowercased(),
                                ]
                            )
                        case .file(let reference):
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_representations(
                                        entry_id, item_index, representation_index,
                                        kind, type_identifier, data_value
                                    ) VALUES (?, ?, ?, 'fileReference', ?, ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    representationIndex,
                                    NSPasteboard.PasteboardType.fileURL.rawValue,
                                    Data(),
                                ]
                            )
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_file_members(
                                        entry_id, item_index, member_index,
                                        captured_path, current_path, display_name,
                                        bookmark_data, resource_type, availability,
                                        identity_data
                                    ) VALUES (?, ?, 0, ?, ?, ?, ?, ?, 'available', ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    reference.capturedPath,
                                    reference.capturedPath,
                                    reference.displayName,
                                    reference.bookmark,
                                    reference.resourceType,
                                    reference.identity,
                                ]
                            )
                            try insertSearchField(
                                reference.displayName,
                                kind: "fileName",
                                index: itemIndex,
                                entryID: storedID,
                                into: database
                            )
                            try insertSearchField(
                                reference.capturedPath,
                                kind: "capturedPath",
                                index: itemIndex,
                                entryID: storedID,
                                into: database
                            )
                            try insertSearchField(
                                reference.capturedPath,
                                kind: "currentPath",
                                index: itemIndex,
                                entryID: storedID,
                                into: database
                            )
                        case .color(let data, let normalizedValue):
                            try database.execute(
                                sql: """
                                    INSERT INTO clipboard_representations(
                                        entry_id, item_index, representation_index,
                                        kind, type_identifier, data_value
                                    ) VALUES (?, ?, ?, 'color', ?, ?)
                                    """,
                                arguments: [
                                    storedID,
                                    itemIndex,
                                    representationIndex,
                                    NSPasteboard.PasteboardType.color.rawValue,
                                    data,
                                ]
                            )
                            try insertSearchField(
                                normalizedValue,
                                kind: "normalizedColor",
                                index: searchFieldIndex,
                                entryID: storedID,
                                into: database
                            )
                            searchFieldIndex += 1
                        }
                    }
                }
                for facet in facets {
                    try database.execute(
                        sql: """
                            INSERT INTO clipboard_entry_facets(entry_id, facet)
                            VALUES (?, ?)
                            """,
                        arguments: [storedID, facet.rawValue]
                    )
                }
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_retention_state(
                            entry_id, retention_started_at, is_protected
                        ) VALUES (?, ?, 0)
                        """,
                    arguments: [storedID, capturedAt.timeIntervalSince1970]
                )
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_duplicate_candidates(
                            fingerprint, entry_id, canonical_byte_count,
                            created_at
                        ) VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        identity.fingerprint,
                        storedID,
                        identity.canonicalByteCount,
                        capturedAt.timeIntervalSince1970,
                    ]
                )
                if !publishedBitmaps.isEmpty {
                    try insertDerivedJob(
                        kind: .qr,
                        entryID: storedID,
                        into: database
                    )
                    if automaticImageTextIndexingEnabled {
                        try insertDerivedJob(
                            kind: .ocr,
                            entryID: storedID,
                            into: database
                        )
                    }
                }
                try Self.bumpSearchIndexGeneration(in: database)
                try Self.bumpHistoryRevision(in: database)
                try faultInjector.check(.databaseTransaction)
            }
        } catch {
            throw mapStorageError(error, entryID: entryID)
        }
        startDerivedJobSchedulerIfNeeded()
        return ClipboardHistoryCaptureOutcome(entryID: entryID)
    }

    private func insertDerivedJob(
        kind: ClipboardHistoryDerivedJobKind,
        entryID: String,
        into database: Database
    ) throws {
        try database.execute(
            sql: """
                INSERT INTO clipboard_derived_jobs(
                    entry_id, kind, state, attempt_count,
                    eligible_generation, next_attempt_at
                ) VALUES (?, ?, 'pending', 0, 1, NULL)
                """,
            arguments: [entryID, kind.rawValue]
        )
    }

    fileprivate struct RepresentationPosition: Hashable {
        let itemIndex: Int
        let representationIndex: Int
    }

    struct CanonicalBitmap {
        let png: Data
        let thumbnail: Data
        let pixelCount: Int
    }

    static func canonicalBitmap(
        from sourceData: Data
    ) throws -> CanonicalBitmap {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        guard let orientedImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        let canonical = try pngData(from: orientedImage)

        guard let canonicalSource = CGImageSourceCreateWithData(
            canonical as CFData,
            nil
        ), let previewImage = CGImageSourceCreateThumbnailAtIndex(
            canonicalSource,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        ) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return CanonicalBitmap(
            png: canonical,
            thumbnail: try pngData(from: previewImage),
            pixelCount: pixelCount
        )
    }

    fileprivate static func imagePixelCount(in sourceData: Data) throws -> Int {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0,
            height > 0
        else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        return pixelCount
    }

    fileprivate static func pngData(from image: CGImage) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipboardHistoryModuleError.storageFailure
        }
        return output as Data
    }

    fileprivate static func fileReference(
        from value: String
    ) throws -> PasteboardSnapshot.FileReference {
        guard let url = URL(string: value),
            url.isFileURL,
            url.path.hasPrefix("/")
        else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let resourceValues = try url.resourceValues(
            forKeys: [
                .contentTypeKey,
                .fileResourceIdentifierKey,
                .nameKey,
            ]
        )
        guard let resourceIdentifier =
            resourceValues.fileResourceIdentifier as? NSObject
        else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let identity = try NSKeyedArchiver.archivedData(
            withRootObject: resourceIdentifier,
            requiringSecureCoding: true
        )
        let bookmark = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [
                .contentTypeKey,
                .fileResourceIdentifierKey,
                .nameKey,
            ],
            relativeTo: nil
        )
        return PasteboardSnapshot.FileReference(
            capturedPath: url.path,
            displayName: resourceValues.name ?? url.lastPathComponent,
            bookmark: bookmark,
            identity: identity,
            resourceType: resourceValues.contentType?.identifier
                ?? UTType(filenameExtension: url.pathExtension)?.identifier
        )
    }

    static func normalizedColor(from data: Data) -> String? {
        guard let color = NSColor(
            pasteboardPropertyList: data,
            ofType: .color
        )?.usingColorSpace(.sRGB) else {
            return nil
        }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        )
        let components = [red, green, blue, alpha].map { component in
            Int((min(max(component, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X%02X",
            components[0],
            components[1],
            components[2],
            components[3]
        )
    }

    static func derivedRichText(
        from data: Data,
        typeIdentifier: String
    ) -> String? {
        if typeIdentifier == NSPasteboard.PasteboardType.html.rawValue {
            guard var html = String(data: data, encoding: .utf8) else {
                return nil
            }
            html = html.replacingOccurrences(
                of: #"(?is)<(?:script|style)\b[^>]*>.*?</(?:script|style)>"#,
                with: " ",
                options: .regularExpression
            )
            html = html.replacingOccurrences(
                of: #"(?i)<br\s*/?>|</p\s*>|</div\s*>|</li\s*>"#,
                with: "\n",
                options: .regularExpression
            )
            html = html.replacingOccurrences(
                of: #"(?s)<[^>]+>"#,
                with: "",
                options: .regularExpression
            )
            for (entity, value) in [
                ("&nbsp;", " "),
                ("&amp;", "&"),
                ("&lt;", "<"),
                ("&gt;", ">"),
                ("&quot;", "\""),
                ("&#39;", "'"),
            ] {
                html = html.replacingOccurrences(of: entity, with: value)
            }
            return html
        }

        let documentType: NSAttributedString.DocumentType
        switch typeIdentifier {
        case NSPasteboard.PasteboardType.rtf.rawValue:
            documentType = .rtf
        case "com.apple.flat-rtfd":
            documentType = .rtfd
        default:
            return nil
        }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: documentType],
            documentAttributes: nil
        ).string
    }

    fileprivate func deriveTextFacets(
        from snapshot: PasteboardSnapshot
    ) -> Set<ClipboardHistoryFacet> {
        var facets: Set<ClipboardHistoryFacet> = []
        for representation in snapshot.items.flatMap(\.representations) {
            switch representation {
            case .text(let typeIdentifier, let value):
                facets.insert(.text)
                if typeIdentifier == NSPasteboard.PasteboardType.URL.rawValue {
                    facets.formUnion(Self.facets(forURLText: value))
                } else if snapshot.allowsTextInference {
                    facets.formUnion(Self.inferredFacets(forExactText: value))
                }
            case .data:
                facets.insert(.text)
            case .bitmap(_, _, let isScreenshot):
                facets.insert(.image)
                if isScreenshot {
                    facets.insert(.screenshot)
                }
            case .file(let reference):
                facets.insert(.file)
                if let resourceType = reference.resourceType,
                    UTType(resourceType)?.conforms(to: .image) == true
                {
                    facets.insert(.image)
                }
            case .color:
                facets.insert(.color)
            }
        }
        facets.formUnion(snapshot.extraFacets)
        return facets
    }

    static func inferredFacets(
        forExactText exactText: String
    ) -> Set<ClipboardHistoryFacet> {
        let value = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }
        var inferred: Set<ClipboardHistoryFacet> = []
        if isMailtoURL(value) {
            inferred.formUnion([.link, .email])
        } else if isBareEmail(value) {
            inferred.insert(.email)
        } else {
            inferred.formUnion(facets(forURLText: value))
        }
        if isColorLiteral(value) {
            inferred.insert(.color)
        }
        return inferred
    }

    fileprivate static func facets(
        forURLText exactText: String
    ) -> Set<ClipboardHistoryFacet> {
        let value = exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
            value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
            !value.contains("{"),
            !value.contains("}")
        else {
            return []
        }
        if isMailtoURL(value) {
            return [.link, .email]
        }
        if let components = URLComponents(string: value),
            components.scheme?.lowercased() == "file"
        {
            return [.file]
        }
        guard isLink(value) else { return [] }
        return [.link]
    }

    fileprivate static func isLink(_ value: String) -> Bool {
        // A bare IPv6 literal has no parsable scheme and only becomes a URL
        // once bracketed, so neither branch below can recognize it.
        var literal = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &literal) }) == 1 {
            return true
        }
        if let scheme = URLComponents(string: value)?.scheme?.lowercased() {
            guard !["javascript", "data", "vbscript", "file", "mailto"]
                .contains(scheme)
            else {
                return false
            }
            // Without `://` this is not a scheme at all: `localhost:3000` and
            // `example.com:8080` parse their host as the scheme, so they have
            // to be re-read as a bare host:port below rather than rejected.
            if value.contains("://") {
                let components = URLComponents(string: value)
                if ["http", "https"].contains(scheme) {
                    return isValidHost(components?.host)
                }
                return Self.matches(
                    scheme,
                    pattern: #"^[A-Za-z][A-Za-z0-9+.-]*$"#
                ) && !(components?.host ?? "").isEmpty
            }
        }

        guard !value.hasPrefix("/"),
            let bare = URLComponents(string: "https://\(value)")
        else {
            return false
        }
        return isValidHost(bare.host)
    }

    fileprivate static func isValidHost(_ host: String?) -> Bool {
        guard let host, !host.isEmpty else { return false }
        if host.lowercased() == "localhost" {
            return true
        }
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1
            || host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
        {
            return true
        }
        guard host.contains("."),
            !host.hasPrefix("."),
            !host.hasSuffix(".")
        else {
            return false
        }
        // Keep the empty subsequences: dropping them let `example..com` pass
        // as the two valid labels around the empty one.
        return host.split(
            separator: ".",
            omittingEmptySubsequences: false
        ).allSatisfy { label in
            Self.matches(
                String(label),
                pattern: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#
            )
        }
    }

    fileprivate static func isBareEmail(_ value: String) -> Bool {
        matches(
            value,
            pattern:
                #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$"#
        )
    }

    fileprivate static func isMailtoURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
            components.scheme?.lowercased() == "mailto"
        else {
            return false
        }
        let recipients = components.path
            .split(separator: ",")
            .map(String.init)
        return !recipients.isEmpty && recipients.allSatisfy(isBareEmail)
    }

    fileprivate static func isColorLiteral(_ value: String) -> Bool {
        let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)"#
        let percentageOrNumber = "\(number)%?"
        let angle = "\(number)(?:deg|grad|rad|turn)?"
        let alpha = percentageOrNumber
        let patterns = [
            #"^#[0-9A-Fa-f]{3}(?:[0-9A-Fa-f])?$"#,
            #"^#[0-9A-Fa-f]{6}(?:[0-9A-Fa-f]{2})?$"#,
            #"(?i)^rgba?\(\s*\#(percentageOrNumber)\s*,\s*\#(percentageOrNumber)\s*,\s*\#(percentageOrNumber)(?:\s*,\s*\#(alpha))?\s*\)$"#,
            #"(?i)^rgba?\(\s*\#(percentageOrNumber)\s+\#(percentageOrNumber)\s+\#(percentageOrNumber)(?:\s*/\s*\#(alpha))?\s*\)$"#,
            #"(?i)^hsla?\(\s*\#(angle)\s*,\s*\#(percentageOrNumber)\s*,\s*\#(percentageOrNumber)(?:\s*,\s*\#(alpha))?\s*\)$"#,
            #"(?i)^hsla?\(\s*\#(angle)\s+\#(percentageOrNumber)\s+\#(percentageOrNumber)(?:\s*/\s*\#(alpha))?\s*\)$"#,
            #"^Color\(red:\s*\#(number),\s*green:\s*\#(number),\s*blue:\s*\#(number)(?:,\s*opacity:\s*\#(number))?\)$"#,
        ]
        return patterns.contains { matches(value, pattern: $0) }
    }

    fileprivate static func matches(
        _ value: String,
        pattern: String
    ) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    fileprivate func insertSearchField(
        _ value: String,
        kind: String,
        index: Int,
        entryID: String,
        into database: Database
    ) throws {
        try Self.insertSearchField(
            value: value,
            kind: kind,
            index: index,
            rankingGroup: Self.searchRankingGroup(for: kind),
            entryID: entryID,
            into: database,
            faultInjector: faultInjector
        )
    }
}
