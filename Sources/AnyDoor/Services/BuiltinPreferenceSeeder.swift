import SwiftData
import OSLog
import Foundation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "seeder")

/// Ensures every BuiltinItem has a corresponding BuiltinPreference row.
///
/// - On first run: seeds all cases with their `defaultOrder`.
/// - On later runs: diffs `BuiltinItem.allCases` against existing rows and appends new items
///   at the end (max displayOrder + 1).
/// - Orphan rows (itemKey not in current `BuiltinItem`) are left in place; readers skip them
///   via `BuiltinItem(rawValue:)`.
enum BuiltinPreferenceSeeder {
    private static let windowLayoutBackfillFlag = "windowLayoutDefaultsApplied_v1"
    private static let clipboardWallHotkeyFlag = "clipboardWallDefaultHotkey_v1"

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

            applyWindowLayoutBackfillIfNeeded(in: context)
            applyClipboardWallHotkeyIfNeeded(in: context)
        } catch {
            logger.error("BuiltinPreference seeding failed: \(error)")
        }
    }

    /// One-shot seed of the default clipboard-wall hotkey (Command+Shift+V).
    /// Skips when the combo is already bound by another built-in, or when the
    /// clipboard-wall row already carries a user-chosen hotkey. The flag is set
    /// regardless of outcome so this only ever runs once.
    @MainActor
    private static func applyClipboardWallHotkeyIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: clipboardWallHotkeyFlag) else { return }
        defer { defaults.set(true, forKey: clipboardWallHotkeyFlag) }   // one-shot regardless of outcome

        // Command+Shift+V — keyCode 9 (kVK_ANSI_V), modifierFlags 0x12_0000 (command|shift).
        let keyCode = 9
        let modifierFlags = 0x12_0000
        do {
            let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
            // Conflict check: if any row already binds this exact combo, leave empty.
            let taken = rows.contains { $0.keyCode == keyCode && $0.modifierFlags == modifierFlags }
            guard !taken else { return }
            guard let row = rows.first(where: { $0.itemKey == BuiltinItem.clipboardWall.rawValue }) else { return }
            guard row.keyCode == nil else { return }   // user already set one
            row.keyCode = keyCode
            row.modifierFlags = modifierFlags
            try context.save()
            logger.info("Seeded default Command+Shift+V hotkey for clipboard wall")
        } catch {
            logger.error("clipboardWall hotkey seed failed: \(error)")
        }
    }

    /// One-shot reset of the four window-children displayOrders to their new
    /// in-popover defaults (2010/2020/2030/2040). Pre-existing users had these
    /// items as top-level rows ordered 2000/2010/2020/2030; without this
    /// rewrite the popover would inherit the old spread (windowLayout parent
    /// shares the 2000 slot) which produces an awkward tie on first launch.
    @MainActor
    private static func applyWindowLayoutBackfillIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: windowLayoutBackfillFlag) else { return }

        let targets: [(BuiltinItem, Double)] = [
            (.windowLeftHalf,  2010),
            (.windowRightHalf, 2020),
            (.windowMaximize,  2030),
            (.windowCenter,    2040),
        ]
        do {
            let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
            let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0) })
            for (item, order) in targets {
                if let row = byKey[item.rawValue] {
                    row.displayOrder = order
                }
            }
            try context.save()
            defaults.set(true, forKey: windowLayoutBackfillFlag)
            logger.info("Applied windowLayout displayOrder backfill")
        } catch {
            logger.error("windowLayout backfill failed: \(error)")
        }
    }
}
