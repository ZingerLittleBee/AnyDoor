import Foundation
import SwiftData
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "seeder")

/// Seeds the curated `QuicklinkTemplateCatalog` presets as real `Quicklink`
/// rows on first launch, so common search templates exist out of the box and
/// can be edited or deleted like any hand-made entry.
///
/// The seed is one-shot (guarded by a UserDefaults flag) and idempotent: each
/// template carries a fixed `uuid`, so re-seeding — or seeding on a second
/// machine before backup/sync merges — reuses the same row identity instead of
/// duplicating. Two collisions are skipped rather than forced:
/// - a template whose `link` already exists (the user made an equivalent row),
/// - a template `keyword` already taken by another row (keeps keywords unique).
enum QuicklinkSeeder {
    private static let seededFlag = "quicklinkTemplatesSeeded_v1"

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: seededFlag) else { return }
        defer { defaults.set(true, forKey: seededFlag) }   // one-shot regardless of outcome

        do {
            let existing = try context.fetch(FetchDescriptor<Quicklink>())
            var takenIDs = Set(existing.map(\.id))
            var takenLinks = Set(existing.map { $0.link.trimmingCharacters(in: .whitespacesAndNewlines) })
            var takenKeywords = Set(existing.compactMap { $0.keyword?.lowercased() })
            var nextOrder = (existing.map(\.displayOrder).max() ?? 0) + 100

            var added = 0
            for template in QuicklinkTemplateCatalog.all {
                let trimmedLink = template.link.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !takenIDs.contains(template.uuid) else { continue }
                guard !takenLinks.contains(trimmedLink) else { continue }

                // Drop a colliding keyword rather than skip the whole preset.
                var keyword = template.keyword
                if let candidate = keyword?.lowercased(), takenKeywords.contains(candidate) {
                    keyword = nil
                }

                let row = Quicklink(
                    id: template.uuid,
                    name: L(template.nameKey),
                    keyword: keyword,
                    link: template.link,
                    displayOrder: nextOrder
                )
                context.insert(row)

                takenIDs.insert(template.uuid)
                takenLinks.insert(trimmedLink)
                if let keyword { takenKeywords.insert(keyword.lowercased()) }
                nextOrder += 100
                added += 1
            }

            if added > 0 {
                try context.save()
                logger.info("Seeded \(added) Quicklink template row(s)")
            }
        } catch {
            logger.error("Quicklink template seeding failed: \(error)")
        }
    }
}
