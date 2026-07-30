import ClipboardHistory
import Foundation
import OSLog
import SwiftData

enum ClipboardHistoryLegacyAdapterError: Error {
    case invalidTags
    case invalidCategoryOrder
}

@MainActor
enum ClipboardHistoryLegacyAdapter {
    private static let logger = Logger(
        subsystem: "dev.bybee.AnyDoor",
        category: "clipboard-history-migration"
    )
    static func makeMigrationRequest(
        modelContext: ModelContext,
        defaults: UserDefaults = .standard,
        payloadDirectory: URL
    ) throws -> ClipboardHistoryLegacyMigrationRequest {
        let rows = try modelContext.fetch(
            FetchDescriptor<ClipboardHistoryItem>(
                sortBy: [
                    SortDescriptor(\.createdAt, order: .reverse)
                ]
            )
        )
        // A row the v1 schema can no longer describe (unknown kind, unreadable
        // file manifest) is dropped, not fatal. Failing the whole transfer
        // would leave the user with no history at all and no way forward: the
        // retry re-reads the same snapshot and hits the same row every time.
        let entries = rows.compactMap(makeLegacyEntry)
        if entries.count != rows.count {
            logger.error(
                """
                Skipped \(rows.count - entries.count, privacy: .public) \
                undecodable legacy clipboard rows during migration
                """
            )
        }
        let tags = try legacyTags(from: defaults)
        let categoryOrder = try legacyCategoryOrder(from: defaults)
        let retention = legacyRetention(from: defaults)
        return ClipboardHistoryLegacyMigrationRequest(
            transfer: ClipboardHistoryLegacyTransfer(
                entries: entries,
                tags: tags,
                categoryOrder: categoryOrder,
                retentionPeriod: retention
            ),
            payloadDirectory: payloadDirectory
        )
    }

    private static func makeLegacyEntry(
        _ row: ClipboardHistoryItem
    ) -> ClipboardHistoryLegacyEntry? {
        guard let kind = ClipboardHistoryKind(rawValue: row.kind) else {
            logger.error(
                "Legacy row \(row.id, privacy: .public) has unknown kind"
            )
            return nil
        }
        let legacyKind: ClipboardHistoryLegacyKind
        switch kind {
        case .text:
            legacyKind = .text
        case .color:
            legacyKind = .color
        case .qrcode:
            legacyKind = .qrCode
        case .ocr:
            legacyKind = .ocr
        case .image:
            legacyKind = .image
        case .screenshot:
            legacyKind = .screenshot
        case .file:
            legacyKind = .file
        }
        let files: [ClipboardHistoryLegacyFileMember]
        if kind == .file {
            guard let manifest = row.filesManifest,
                let decoded = try? JSONDecoder().decode(
                    [ClipboardFileEntry].self,
                    from: manifest
                ),
                !decoded.isEmpty
            else {
                logger.error(
                    """
                    Legacy row \(row.id, privacy: .public) has an unreadable \
                    file manifest
                    """
                )
                return nil
            }
            files = decoded.map {
                ClipboardHistoryLegacyFileMember(
                    storedName: $0.storedName,
                    originalName: $0.originalName,
                    originalPath: $0.originalPath
                )
            }
        } else {
            files = []
        }
        return ClipboardHistoryLegacyEntry(
            id: row.id,
            kind: legacyKind,
            text: row.text,
            fileName: row.fileName,
            colorHex: row.colorHex,
            previewText: row.previewTitle,
            capturedAt: row.createdAt,
            richData: row.richData,
            richType: row.richType,
            source: ClipboardHistoryCaptureSource(
                bundleIdentifier: row.sourceBundleID,
                displayName: row.sourceAppName,
                provenance: .legacy
            ),
            isFavorite: row.isFavorite,
            tagIDs: row.tagIDs,
            files: files
        )
    }

    private static func legacyTags(
        from defaults: UserDefaults
    ) throws -> [ClipboardHistoryLegacyTag] {
        guard
            let json = defaults.string(
                forKey: ClipboardHistoryPortableKeys.customTags
            )
        else {
            return []
        }
        guard let data = json.data(using: .utf8),
            let tags = try? JSONDecoder().decode(
                [ClipboardTag].self,
                from: data
            )
        else {
            throw ClipboardHistoryLegacyAdapterError.invalidTags
        }
        return tags.map {
            ClipboardHistoryLegacyTag(id: $0.id, name: $0.name)
        }
    }

    private static func legacyCategoryOrder(
        from defaults: UserDefaults
    ) throws -> [String] {
        guard
            let json = defaults.string(
                forKey: ClipboardCategoryOrder.defaultsKey
            )
        else {
            return []
        }
        guard let data = json.data(using: .utf8),
            let order = try? JSONDecoder().decode(
                [String].self,
                from: data
            )
        else {
            throw ClipboardHistoryLegacyAdapterError.invalidCategoryOrder
        }
        return order
    }

    private static func legacyRetention(
        from defaults: UserDefaults
    ) -> ClipboardHistoryRetentionPeriod {
        let rawValue =
            defaults.object(forKey: ClipboardPreferences.retentionKey)
                as? Int ?? ClipboardRetention.thirtyDays.rawValue
        switch ClipboardRetention(rawValue: rawValue) ?? .thirtyDays {
        case .oneDay:
            return .oneDay
        case .sevenDays:
            return .sevenDays
        case .thirtyDays:
            return .thirtyDays
        case .ninetyDays:
            return .ninetyDays
        case .oneHundredEightyDays:
            return .oneHundredEightyDays
        case .threeHundredSixtyFiveDays:
            return .threeHundredSixtyFiveDays
        case .unlimited:
            return .unlimited
        }
    }
}
