import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "seeder")

/// Ensures every BuiltinItem has a corresponding BuiltinPreference row.
///
/// - On first run: seeds all cases with their `defaultOrder`.
/// - On later runs: diffs `BuiltinItem.allCases` against existing rows and appends new items
///   at the end (max displayOrder + 1).
/// - Orphan rows (itemKey not in current `BuiltinItem`) are left in place; readers skip them
///   via `BuiltinItem(rawValue:)`.
enum BuiltinPreferenceSeeder {
    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        do {
            let existing = try context.fetch(FetchDescriptor<BuiltinPreference>())
            let existingKeys = Set(existing.map(\.itemKey))
            let maxOrder = existing.map(\.displayOrder).max() ?? 0

            var addedAt = max(maxOrder + 100, 0)
            var added = 0
            for item in BuiltinItem.allCases {
                guard !existingKeys.contains(item.rawValue) else { continue }
                let order = existing.isEmpty ? item.defaultOrder : addedAt
                let pref = BuiltinPreference(
                    itemKey: item.rawValue,
                    isVisible: item.defaultVisibility,
                    displayOrder: order,
                    keyCode: nil,
                    modifierFlags: nil
                )
                context.insert(pref)
                addedAt += 100
                added += 1
            }
            if added > 0 {
                try context.save()
                logger.info("Seeded \(added) BuiltinPreference row(s)")
            }
        } catch {
            logger.error("BuiltinPreference seeding failed: \(error)")
        }
    }
}
