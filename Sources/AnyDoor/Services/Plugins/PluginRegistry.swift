import Foundation
import Observation
import OSLog
import PluginInterface
import SwiftData

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "plugins")

struct PluginImportFailure: Equatable, Sendable {
    let pluginID: NativePluginID
    let pluginName: String
    let errorDescription: String
}

struct PluginImportReconciliationError: LocalizedError, Equatable, Sendable {
    let failures: [PluginImportFailure]

    var errorDescription: String? {
        failures
            .map { "\($0.pluginName): \($0.errorDescription)" }
            .joined(separator: "\n")
    }
}

struct PluginTransitionInProgressError: LocalizedError, Equatable, Sendable {
    let pluginID: NativePluginID
    let message: String

    var errorDescription: String? { message }
}

/// The single seam between the Core and the Native Plugins (ADR-0005).
///
/// Receives the catalog-built plugin instances, owns the install-state store,
/// and answers claim lookups (ADR-0006: every `BuiltinItem` is owned by
/// exactly one Native Plugin or by the Core), and runs the transactional
/// install/uninstall lifecycle. Surfaces never ask a plugin anything
/// directly — they ask the registry whether a command is available, and the
/// registry publishes the composed surfaces when the installed set changes.
///
/// Uninstall is transactional: `deactivate()` must succeed before any state
/// or surface changes; a thrown error leaves the plugin fully installed.
@MainActor
@Observable
final class PluginRegistry {
    static let shared = PluginRegistry()

    /// UserDefaults key holding the installed plugin ids ([String]).
    /// Whitelisted in `SyncSettingsRegistry`, so the set travels in config
    /// backup; nonisolated so `SyncSettingsRegistry` (a plain enum, not
    /// MainActor-bound like this class) can reference it.
    nonisolated static let installStateKey = "plugins.installed"

    private(set) var plugins: [any NativePlugin] = []
    private(set) var installedIDs: Set<NativePluginID> = []

    @ObservationIgnored private let panelStore: PanelStore
    @ObservationIgnored private let paletteExtensions: CommandPaletteExtensions
    @ObservationIgnored private let hotkeyCoordinator: HotkeyCoordinator
    @ObservationIgnored private let refreshCommandPalette: @MainActor () -> Void
    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var claims: [BuiltinItem: NativePluginID] = [:]
    @ObservationIgnored private var isBootstrapped = false
    /// Re-entrancy guard: ids with an uninstall's async deactivate in flight.
    @ObservationIgnored private var transitioningIDs: Set<NativePluginID> = []

    init(
        panelStore: PanelStore = .shared,
        paletteExtensions: CommandPaletteExtensions = .shared,
        hotkeyCoordinator: HotkeyCoordinator = .shared,
        refreshCommandPalette: @escaping @MainActor () -> Void = {
            CommandPaletteWindowController.shared.refreshPluginSurfaces()
        }
    ) {
        self.panelStore = panelStore
        self.paletteExtensions = paletteExtensions
        self.hotkeyCoordinator = hotkeyCoordinator
        self.refreshCommandPalette = refreshCommandPalette
    }

    /// Load the install state, activate every installed plugin, and compose
    /// all initial surfaces. Runtime state starts empty so cold-launch
    /// activation follows the same activate-before-Installed invariant as a
    /// hands-on Install. Initial surface publication is batched because launch
    /// has no suspension point and no plugin surface is visible yet.
    func bootstrap(
        plugins: [any NativePlugin],
        modelContainer: ModelContainer,
        coreProviders: [any BuiltinProvider],
        defaults: UserDefaults = .standard
    ) {
        precondition(!isBootstrapped, "PluginRegistry.bootstrap may only run once")
        isBootstrapped = true
        self.plugins = plugins
        self.defaults = defaults

        claims = [:]
        var pluginIDs: Set<NativePluginID> = []
        for plugin in plugins {
            if !pluginIDs.insert(plugin.id).inserted {
                assertionFailure("Duplicate Native Plugin id: \(plugin.id.rawValue)")
            }
            for command in plugin.claimedCommands {
                if let owner = claims[command] {
                    // A duplicate claim is a programming error; the catalog
                    // invariant test pins it. Keep the first claim so the
                    // failure mode is deterministic.
                    assertionFailure(
                        "\(command) claimed by both \(owner.rawValue) and \(plugin.id.rawValue)"
                    )
                    continue
                }
                claims[command] = plugin.id
            }
        }

        let storedIDs = (defaults.stringArray(forKey: Self.installStateKey) ?? [])
            .map(NativePluginID.init(rawValue:))
        let targetInstalledIDs = Set(storedIDs).intersection(pluginIDs)
        installedIDs = []

        for plugin in plugins where targetInstalledIDs.contains(plugin.id) {
            activateAndEnterInstalled(plugin)
        }

        let installedPlugins = plugins.filter { installedIDs.contains($0.id) }
        let providers = coreProviders + installedPlugins.flatMap(\.providers)
        panelStore.bootstrap(
            modelContainer: modelContainer,
            providers: providers,
            commandAvailability: { [weak self] in self?.isAvailable($0) ?? true },
            refreshHotkeys: { [weak hotkeyCoordinator = self.hotkeyCoordinator] in
                hotkeyCoordinator?.refresh()
            }
        )
        for plugin in installedPlugins {
            paletteExtensions.registerContributions(of: plugin)
        }
        hotkeyCoordinator.bootstrap(
            modelContainer: modelContainer,
            availableCommands: { [weak self] in
                self?.availableCommands ?? Set(BuiltinItem.allCases)
            },
            toggleBuiltin: { [weak panelStore = self.panelStore] item in
                await panelStore?.toggle(item)
            },
            runBuiltin: { [weak panelStore = self.panelStore] item in
                await panelStore?.run(item)
            }
        )
    }

    // MARK: - Lookups

    func plugin(withID id: NativePluginID) -> (any NativePlugin)? {
        plugins.first { $0.id == id }
    }

    func isInstalled(_ id: NativePluginID) -> Bool {
        installedIDs.contains(id)
    }

    /// The plugin owning a command's Claim, or nil when the Core owns it.
    func claimOwner(of command: BuiltinItem) -> NativePluginID? {
        claims[command]
    }

    /// Whether a command currently exists for the user: Core-owned commands
    /// always do; plugin-claimed commands only while their plugin is
    /// installed. Surfaces (panel rows, palette entries, hotkey compilation,
    /// the clipboard context menu) gate on this.
    func isAvailable(_ command: BuiltinItem) -> Bool {
        guard let owner = claims[command] else { return true }
        return installedIDs.contains(owner)
    }

    /// The full catalog minus uninstalled plugins' claims — the installed-set
    /// input to hotkey snapshot compilation.
    var availableCommands: Set<BuiltinItem> {
        var commands = Set(BuiltinItem.allCases)
        for plugin in plugins where !installedIDs.contains(plugin.id) {
            commands.subtract(plugin.claimedCommands)
        }
        return commands
    }

    /// The panel popover for a claimed submenu command, or nil when the Core
    /// owns the command or its plugin is not installed — an uninstalled
    /// plugin's popover must never mount.
    func panelPopover(for command: BuiltinItem) -> PluginPanelPopover? {
        guard let owner = claims[command],
              installedIDs.contains(owner),
              let plugin = plugin(withID: owner) else { return nil }
        return plugin.panelPopover(for: command)
    }

    // MARK: - Lifecycle

    /// Install a plugin: activate it, persist the state, and register its
    /// surfaces. Takes effect immediately — no relaunch. Idempotent.
    func install(_ id: NativePluginID) {
        guard let plugin = plugin(withID: id),
              !installedIDs.contains(id),
              !transitioningIDs.contains(id) else { return }
        hotkeyCoordinator.resolveRetainedPluginHotkeyConflicts(
            for: plugin.claimedCommands,
            activeCommands: availableCommands
        )
        activateAndEnterInstalled(plugin)
        persistInstalledIDs()
        panelStore.registerProviders(plugin.providers)
        paletteExtensions.registerContributions(of: plugin)
        refreshSurfaces()
        logger.info("Installed plugin \(id.rawValue)")
    }

    /// Uninstall a plugin, transactionally: `deactivate()` (release shared
    /// resources, cancel in-flight work) must succeed before any state or
    /// surface changes; on a thrown error the plugin stays fully installed
    /// and the error is rethrown for the UI to surface. User data is
    /// retained by design. Idempotent; a concurrent transition is reported.
    func uninstall(_ id: NativePluginID) async throws {
        guard let plugin = plugin(withID: id),
              installedIDs.contains(id) else { return }
        guard !transitioningIDs.contains(id) else {
            throw transitionInProgressError(for: plugin)
        }
        transitioningIDs.insert(id)
        defer { transitioningIDs.remove(id) }

        try await plugin.deactivate()

        installedIDs.remove(id)
        persistInstalledIDs()
        panelStore.unregisterProviders(for: plugin.claimedCommands)
        paletteExtensions.unregisterContributions(of: plugin)
        refreshSurfaces()
        logger.info("Uninstalled plugin \(id.rawValue)")
    }

    /// Adopt an imported install state, then forward the import to the
    /// plugins that end up installed.
    ///
    /// The settings import only wrote the installed set into defaults;
    /// installing/uninstalling here runs the real lifecycle (activate /
    /// deactivate plus surface publication), so an imported selection behaves
    /// like hands-on installs — surfaces appear or disappear without a
    /// relaunch. A failed deactivate keeps its plugin installed (the usual
    /// transactional rule) and the stored state is re-persisted to match
    /// reality.
    func reconcileAfterImport() async throws {
        let importedIDs = Set(
            (defaults.stringArray(forKey: Self.installStateKey) ?? [])
                .map(NativePluginID.init(rawValue:))
        ).intersection(Set(plugins.map(\.id)))

        var failures: [PluginImportFailure] = []

        // MainActor methods are re-entrant across `await`. An uninstall that
        // started before the import may still reverse the imported target after
        // this method returns, so the import cannot claim convergence for that
        // plugin. Report it and persist the current truth; the caller can retry
        // once the existing transition completes.
        let blockedIDs = transitioningIDs
        for plugin in plugins where blockedIDs.contains(plugin.id) {
            failures.append(importFailure(
                for: plugin,
                error: transitionInProgressError(for: plugin)
            ))
        }

        // Remove first so returning plugins resolve retained hotkeys against
        // the actual survivors, including any plugin whose deactivate failed.
        let idsToRemove = installedIDs.subtracting(importedIDs).subtracting(blockedIDs)
        for plugin in plugins where idsToRemove.contains(plugin.id) {
            do {
                try await uninstall(plugin.id)
            } catch {
                logger.error("Import-driven uninstall of \(plugin.id.rawValue) failed: \(error)")
                failures.append(importFailure(for: plugin, error: error))
            }
        }
        let idsToInstall = importedIDs.subtracting(installedIDs).subtracting(blockedIDs)
        for plugin in plugins where idsToInstall.contains(plugin.id) {
            install(plugin.id)
        }

        // Another caller may have entered during one of the awaited removals.
        // Re-check before the final synchronous segment so no transition can
        // outlive a successful reconciliation unnoticed.
        let reportedFailureIDs = Set(failures.map(\.pluginID))
        for plugin in plugins
        where transitioningIDs.contains(plugin.id)
            && !reportedFailureIDs.contains(plugin.id) {
            failures.append(importFailure(
                for: plugin,
                error: transitionInProgressError(for: plugin)
            ))
        }
        persistInstalledIDs()

        for plugin in plugins where installedIDs.contains(plugin.id) {
            plugin.reconcileAfterImport()
        }

        if !failures.isEmpty {
            throw PluginImportReconciliationError(failures: failures)
        }
    }

    private func persistInstalledIDs() {
        defaults.set(installedIDs.map(\.rawValue).sorted(), forKey: Self.installStateKey)
    }

    private func activateAndEnterInstalled(_ plugin: any NativePlugin) {
        plugin.activate()
        installedIDs.insert(plugin.id)
    }

    private func refreshSurfaces() {
        panelStore.rebuild()
        hotkeyCoordinator.refresh()
        refreshCommandPalette()
    }

    private func transitionInProgressError(
        for plugin: any NativePlugin
    ) -> PluginTransitionInProgressError {
        PluginTransitionInProgressError(
            pluginID: plugin.id,
            message: L(.pluginsTransitionInProgress)
        )
    }

    private func importFailure(
        for plugin: any NativePlugin,
        error: any Error
    ) -> PluginImportFailure {
        PluginImportFailure(
            pluginID: plugin.id,
            pluginName: plugin.localizedName,
            errorDescription: error.localizedDescription
        )
    }
}
