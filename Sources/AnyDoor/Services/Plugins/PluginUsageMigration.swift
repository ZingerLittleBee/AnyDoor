import Foundation
import OSLog
import PluginInterface
import SwiftData

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "plugins")

/// One-time, versioned backfill of the Native Plugin install state for users
/// upgrading across the plugin split (PRD Migration decision; follows the
/// `BuiltinPreferenceSeeder` one-shot-flag precedent).
///
/// Each plugin's usage-trace predicate decides its initial install state:
/// whoever shows a trace of prior use is installed so the upgrade changes
/// nothing perceivable; everyone else — including fresh installs — starts
/// uninstalled. Runs before `PluginRegistry.bootstrap` in the launch
/// sequence, so it only writes the install-state store directly; the
/// registry bootstrap then activates the migrated-installed plugins and
/// composes their surfaces through the normal launch path.
enum PluginUsageMigration {
    /// Versioned one-shot flag: once set the migration never runs again, so
    /// no relaunch — including Sparkle's silent-update relaunch — can change
    /// an already-migrated installed set.
    static let migrationFlagKey = "plugins.usageMigrated_v1"

    @MainActor
    static func runIfNeeded(
        plugins: [any NativePlugin],
        in context: ModelContext,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationFlagKey) else { return }

        // An install state present before the first migrated launch can only
        // come from a config-backup import; that explicit selection beats the
        // usage-trace inference.
        if defaults.object(forKey: PluginRegistry.installStateKey) != nil {
            defaults.set(true, forKey: migrationFlagKey)
            return
        }

        var installed: [String] = []
        for plugin in plugins {
            do {
                if try plugin.hasUsageTrace(in: context) {
                    installed.append(plugin.id.rawValue)
                }
            } catch {
                // A transient store error must not lock in a wrong answer
                // (silently uninstalling a feature the user relied on): leave
                // the flag unset so the next launch retries the migration.
                logger.error(
                    "Usage-trace migration failed for \(plugin.id.rawValue): \(error)"
                )
                return
            }
        }
        defaults.set(installed.sorted(), forKey: PluginRegistry.installStateKey)
        defaults.set(true, forKey: migrationFlagKey)
        logger.info("Usage-trace migration installed \(installed.sorted())")
    }
}
