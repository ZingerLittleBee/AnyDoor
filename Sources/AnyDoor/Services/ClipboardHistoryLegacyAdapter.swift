import ClipboardHistory
import Foundation
import OSLog

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

    /// Builds the migration request from a legacy store snapshot, or from
    /// defaults alone when `storeURL` is nil (no pre-v2 store ever existed).
    static func makeMigrationRequest(
        storeURL: URL?,
        defaults: UserDefaults = .standard,
        payloadDirectory: URL
    ) throws -> ClipboardHistoryLegacyMigrationRequest {
        // Newest first: `recency_order` is assigned downstream straight from
        // this sequence.
        //
        // A row the v1 schema can no longer describe (unknown kind, unreadable
        // file manifest) is dropped, not fatal. Failing the whole transfer
        // would leave the user with no history at all and no way forward: the
        // retry re-reads the same snapshot and hits the same row every time.
        var skipped = 0
        let entries: [ClipboardHistoryLegacyEntry]
        if let storeURL {
            entries = try ClipboardHistoryLegacyStoreReader.readEntries(
                at: storeURL
            ) { row in
                skipped += 1
                logger.error(
                    """
                    Skipped legacy clipboard row \
                    \(row.id?.uuidString ?? "<unreadable id>", privacy: .public): \
                    \(String(describing: row.reason), privacy: .public)
                    """
                )
            }
        } else {
            entries = []
        }
        if skipped > 0 {
            logger.error(
                """
                Skipped \(skipped, privacy: .public) undecodable legacy \
                clipboard rows during migration
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
