import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "backfill")

/// One-time backfill: assigns ascending `displayOrder` values to legacy KeyBinding rows
/// that came from earlier versions without ordering (i.e. `displayOrder == 0`).
/// Order is by `createdAt` ascending, with a stride of 100 so users can insert in between.
enum KeyBindingOrderBackfill {
    @MainActor
    static func runIfNeeded(in context: ModelContext) {
        do {
            let rows = try context.fetch(FetchDescriptor<KeyBinding>(
                sortBy: [SortDescriptor(\.createdAt)]
            ))
            // If any row has a non-zero order, assume backfill is already done.
            guard rows.contains(where: { $0.displayOrder == 0 }) else { return }
            guard !rows.allSatisfy({ $0.displayOrder != 0 }) else { return }

            var order: Double = 100
            for row in rows where row.displayOrder == 0 {
                row.displayOrder = order
                order += 100
            }
            try context.save()
            logger.info("Backfilled displayOrder on \(rows.count) KeyBinding row(s)")
        } catch {
            logger.error("KeyBinding displayOrder backfill failed: \(error)")
        }
    }
}
