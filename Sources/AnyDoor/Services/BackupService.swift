import Foundation
import AppKit
import ClipboardHistory
import SwiftData

/// Outcome of an import, surfaced to the UI.
struct ImportSummary: Equatable {
    var shortcutsUpdated: Int
    var shortcutsInserted: Int
    var preferencesUpdated: Int
    var quicklinksUpdated: Int
    var quicklinksInserted: Int
    var settingsApplied: Int
}

/// Gathers local config into a `BackupSnapshot` (export) and merges a snapshot
/// back into local state (import). Operates on an injected `ModelContext` +
/// `UserDefaults` so it is fully testable with an in-memory container.
@MainActor
final class BackupService {
    private static var reconcileClipboardHistory:
        @MainActor () async throws -> Void = {}

    private let context: ModelContext
    private let defaults: UserDefaults
    private let appPathResolver: (String) -> String?
    private let reconcileRuntime: @MainActor () async throws -> Void

    /// - Parameter appPathResolver: bundleID → absolute path. Defaults to
    ///   `NSWorkspace`. Injected as `{ _ in nil }` in tests.
    init(
        context: ModelContext,
        defaults: UserDefaults = .standard,
        appPathResolver: @escaping (String) -> String? = { bundleID in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        },
        reconcileRuntime: @escaping @MainActor () async throws -> Void = {
            try await BackupService.reconcileLiveRuntime()
        }
    ) {
        self.context = context
        self.defaults = defaults
        self.appPathResolver = appPathResolver
        self.reconcileRuntime = reconcileRuntime
    }

    static func configureClipboardHistoryRuntime(
        module: ClipboardHistoryModule,
        lifecycle: ClipboardHistoryLifecycle
    ) {
        reconcileClipboardHistory = {
            try await ClipboardHistoryPortableSettings.reconcile(
                module: module
            )
            await lifecycle.refreshMonitoringConfiguration()
        }
    }

    // MARK: - Export

    /// Throws if a store read fails, so a transient fetch error surfaces to the
    /// caller instead of silently producing (and writing) an empty backup that
    /// would overwrite a good one.
    func exportSnapshot() throws -> BackupSnapshot {
        let bindings = try context.fetch(
            FetchDescriptor<KeyBinding>(sortBy: [SortDescriptor(\.displayOrder)])
        )
        let shortcuts = bindings.map(AppShortcutDTO.init)

        let prefs = try context.fetch(
            FetchDescriptor<BuiltinPreference>(sortBy: [SortDescriptor(\.displayOrder)])
        )
        let preferences = prefs.map(BuiltinPreferenceDTO.init)

        let quicklinkRows = try context.fetch(
            FetchDescriptor<Quicklink>(
                sortBy: [
                    SortDescriptor(\.displayOrder),
                    SortDescriptor(\.createdAt),
                ]
            )
        )
        let quicklinks = quicklinkRows.map(QuicklinkDTO.init)

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"

        return BackupSnapshot(
            schemaVersion: BackupSnapshot.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: appVersion,
            deviceName: Host.current().localizedName,
            appShortcuts: shortcuts,
            builtinPreferences: preferences,
            quicklinks: quicklinks,
            settings: SyncSettingsRegistry.read(from: defaults)
        )
    }

    // MARK: - Restore (merge; import wins per key, local-only rows preserved)

    /// Apply a snapshot and wait until every live subsystem has converged on
    /// the imported state. Callers cannot observe a successful restore while
    /// plugin lifecycle or derived surfaces are still stale.
    @discardableResult
    func restore(_ snapshot: BackupSnapshot) async throws -> ImportSummary {
        let summary = try apply(snapshot)
        try await reconcileRuntime()
        // Restored rows are portable config the sync engine (if running)
        // must capture; settings writes already fired the defaults notification.
        NotificationCenter.default.post(name: .portableConfigDidChange, object: nil)
        return summary
    }

    private func apply(_ snapshot: BackupSnapshot) throws -> ImportSummary {
        var summary = ImportSummary(shortcutsUpdated: 0, shortcutsInserted: 0,
                                    preferencesUpdated: 0, quicklinksUpdated: 0,
                                    quicklinksInserted: 0, settingsApplied: 0)

        // App shortcuts — match by appBundleID.
        let existingBindings = try context.fetch(FetchDescriptor<KeyBinding>())
        // KeyBinding.appBundleID is not unique-constrained; on the rare duplicate, prefer the most recently inserted row.
        var bindingsByID = Dictionary(
            existingBindings.map { ($0.appBundleID, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for dto in snapshot.appShortcuts {
            let resolvedPath = appPathResolver(dto.appBundleID) ?? ""
            if let existing = bindingsByID[dto.appBundleID] {
                existing.keyCode = dto.keyCode
                existing.modifierFlags = dto.modifierFlags
                existing.isEnabled = dto.isEnabled
                existing.isVisible = dto.isVisible
                existing.displayOrder = dto.displayOrder
                existing.appName = dto.appName
                existing.appPath = resolvedPath
                summary.shortcutsUpdated += 1
            } else {
                let new = KeyBinding(
                    keyCode: dto.keyCode, modifierFlags: dto.modifierFlags,
                    appBundleID: dto.appBundleID, appName: dto.appName,
                    appPath: resolvedPath,
                    isEnabled: dto.isEnabled, isVisible: dto.isVisible,
                    displayOrder: dto.displayOrder
                )
                context.insert(new)
                bindingsByID[dto.appBundleID] = new
                summary.shortcutsInserted += 1
            }
        }

        // Builtin preferences — match by itemKey; never insert unknown keys
        // (the local catalog is the source of truth for which items exist).
        let existingPrefs = try context.fetch(FetchDescriptor<BuiltinPreference>())
        let prefsByKey = Dictionary(
            existingPrefs.map { ($0.itemKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for dto in snapshot.builtinPreferences {
            guard let existing = prefsByKey[dto.itemKey] else { continue }
            existing.isVisible = dto.isVisible
            existing.displayOrder = dto.displayOrder
            existing.keyCode = dto.keyCode
            existing.modifierFlags = dto.modifierFlags
            summary.preferencesUpdated += 1
        }

        // Quicklinks — match by stable row id. Imported rows own their keyword:
        // a differently-id'd local row with the same keyword is kept, but its
        // keyword is cleared so palette inline matching stays deterministic.
        var existingQuicklinks = try context.fetch(FetchDescriptor<Quicklink>())
        var quicklinksByID = Dictionary(
            existingQuicklinks.map { ($0.id, $0) },
            uniquingKeysWith: { _, last in last }
        )
        for dto in snapshot.quicklinks {
            guard let link = sanitizedQuicklinkLink(dto.link) else { continue }
            let keyword = sanitizedQuicklinkKeyword(dto.keyword)
            clearConflictingQuicklinkKeywords(
                keyword: keyword,
                ownerID: dto.id,
                rows: existingQuicklinks
            )
            if let existing = quicklinksByID[dto.id] {
                applyQuicklinkDTO(dto, link: link, keyword: keyword, to: existing)
                summary.quicklinksUpdated += 1
            } else {
                let row = Quicklink(
                    id: dto.id,
                    name: dto.name,
                    keyword: keyword,
                    link: link,
                    openWithBundleID: QuicklinkOpenWith.normalizedBundleID(dto.openWithBundleID),
                    keyCode: dto.keyCode,
                    modifierFlags: dto.modifierFlags,
                    isVisible: dto.isVisible,
                    displayOrder: dto.displayOrder,
                    createdAt: dto.createdAt
                )
                context.insert(row)
                existingQuicklinks.append(row)
                quicklinksByID[dto.id] = row
                summary.quicklinksInserted += 1
            }
        }

        try context.save()

        // Settings — whitelisted UserDefaults.
        summary.settingsApplied = SyncSettingsRegistry.write(snapshot.settings, to: defaults)

        return summary
    }

    /// Re-read settings into the modules whose setters carry side effects that
    /// raw UserDefaults writes bypass, then rebuild derived surfaces. Shared
    /// with `SyncEngine`, whose applies bypass the same setters.
    static func reconcileLiveRuntime() async throws {
        CommandPaletteService.shared.reloadFromDefaults()
        LocalizationManager.shared.reloadFromDefaults()
        await HyperKeyService.shared.reloadFromDefaults()
        ScheduledShutdownService.shared.reloadFromDefaults()
        CaptureSettings.shared.reloadFromDefaults()
        TranslationSettings.shared.reloadFromDefaults()
        // Both reconcilers are best-effort across every requested transition:
        // a failure must not skip the remaining live refreshes below, or an
        // import would silently leave quicklinks, panel rows, and hotkeys
        // stale. Failures are collected and rethrown once everything else has
        // converged.
        let pluginError: (any Error)?
        do {
            try await PluginRegistry.shared.reconcileAfterImport()
            pluginError = nil
        } catch {
            pluginError = error
        }
        let clipboardHistoryError: (any Error)?
        do {
            try await reconcileClipboardHistory()
            clipboardHistoryError = nil
        } catch {
            clipboardHistoryError = error
        }
        QuicklinkStore.shared.rebuild()
        PanelStore.shared.rebuild()
        HotkeyCoordinator.shared.refresh()

        if let pluginError {
            throw pluginError
        }
        if let clipboardHistoryError {
            throw clipboardHistoryError
        }
    }

    private func sanitizedQuicklinkLink(_ link: String) -> String? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizedQuicklinkKeyword(_ keyword: String?) -> String? {
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clearConflictingQuicklinkKeywords(
        keyword: String?,
        ownerID: UUID,
        rows: [Quicklink]
    ) {
        guard let keyword else { return }
        for row in rows where row.id != ownerID {
            guard let existing = sanitizedQuicklinkKeyword(row.keyword),
                  existing.compare(keyword, options: [.caseInsensitive]) == .orderedSame
            else { continue }
            row.keyword = nil
        }
    }

    private func applyQuicklinkDTO(
        _ dto: QuicklinkDTO,
        link: String,
        keyword: String?,
        to row: Quicklink
    ) {
        row.name = dto.name
        row.keyword = keyword
        row.link = link
        row.openWithBundleID = QuicklinkOpenWith.normalizedBundleID(dto.openWithBundleID)
        row.keyCode = dto.keyCode
        row.modifierFlags = dto.modifierFlags
        row.isVisible = dto.isVisible
        row.displayOrder = dto.displayOrder
        row.createdAt = dto.createdAt
    }
}
