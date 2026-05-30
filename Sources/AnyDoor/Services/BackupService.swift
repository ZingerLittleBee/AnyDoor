import Foundation
import AppKit
import SwiftData

/// Outcome of an import, surfaced to the UI.
struct ImportSummary: Equatable {
    var shortcutsUpdated: Int
    var shortcutsInserted: Int
    var preferencesUpdated: Int
    var settingsApplied: Int
}

/// Gathers local config into a `BackupSnapshot` (export) and merges a snapshot
/// back into local state (import). Operates on an injected `ModelContext` +
/// `UserDefaults` so it is fully testable with an in-memory container.
@MainActor
final class BackupService {
    private let context: ModelContext
    private let defaults: UserDefaults
    private let appPathResolver: (String) -> String?

    /// - Parameter appPathResolver: bundleID → absolute path. Defaults to
    ///   `NSWorkspace`. Injected as `{ _ in nil }` in tests.
    init(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        appPathResolver: @escaping (String) -> String? = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        }
    ) {
        self.context = context
        self.defaults = defaults
        self.appPathResolver = appPathResolver
    }

    // MARK: - Export

    func exportSnapshot() -> BackupSnapshot {
        let bindings = (try? context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let shortcuts = bindings.map { b in
            AppShortcutDTO(
                appBundleID: b.appBundleID, appName: b.appName,
                keyCode: b.keyCode, modifierFlags: b.modifierFlags,
                isEnabled: b.isEnabled, isVisible: b.isVisible,
                displayOrder: b.displayOrder
            )
        }

        let prefs = (try? context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        )) ?? []
        let preferences = prefs.map { p in
            BuiltinPreferenceDTO(
                itemKey: p.itemKey, isVisible: p.isVisible,
                displayOrder: p.displayOrder,
                keyCode: p.keyCode, modifierFlags: p.modifierFlags
            )
        }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        return BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            deviceName: Host.current().localizedName,
            appShortcuts: shortcuts,
            builtinPreferences: preferences,
            settings: SyncSettingsRegistry.read(from: defaults)
        )
    }
}
