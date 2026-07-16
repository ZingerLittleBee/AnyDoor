import Foundation
import Observation
import OSLog
import PluginInterface

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "plugins")

/// The single seam between the Core and the Native Plugins (ADR-0005).
///
/// Owns the compile-time plugin list and the install-state store, answers
/// claim lookups (ADR-0006: every `BuiltinItem` is owned by exactly one
/// Native Plugin or by the Core), and runs the transactional
/// install/uninstall lifecycle. Surfaces never ask a plugin anything
/// directly — they ask the registry whether a command is available, and the
/// registry drives the surface hooks when the installed set changes.
///
/// Uninstall is transactional: `deactivate()` must succeed before any state
/// or surface changes; a thrown error (including a cancelled required
/// authorization) leaves the plugin fully installed.
@MainActor
@Observable
final class PluginRegistry {
    static let shared = PluginRegistry()

    /// UserDefaults key holding the installed plugin ids ([String]).
    /// Joins the settings-sync whitelist with the migration slice.
    static let installStateKey = "plugins.installed"

    /// How the registry pushes installed-set changes into the Core's
    /// surfaces. Injected at bootstrap so the lifecycle stays testable
    /// against real stores without reaching for app-global singletons.
    struct SurfaceHooks {
        var registerProviders: @MainActor ([any BuiltinProvider]) -> Void
        var unregisterProviders: @MainActor (Set<BuiltinItem>) -> Void
        var refreshSurfaces: @MainActor () -> Void

        static let noop = SurfaceHooks(
            registerProviders: { _ in },
            unregisterProviders: { _ in },
            refreshSurfaces: {}
        )
    }

    private(set) var plugins: [any NativePlugin] = []
    private(set) var installedIDs: Set<NativePluginID> = []

    @ObservationIgnored private var defaults: UserDefaults = .standard
    @ObservationIgnored private var hooks: SurfaceHooks = .noop
    @ObservationIgnored private var claims: [BuiltinItem: NativePluginID] = [:]
    /// Re-entrancy guard: ids with an uninstall's async deactivate in flight.
    @ObservationIgnored private var transitioningIDs: Set<NativePluginID> = []

    /// Load the install state and activate every installed plugin. Does NOT
    /// fire the surface hooks — the caller composes the initial surfaces from
    /// `installedProviders` itself; hooks only fire on later state changes.
    func bootstrap(
        plugins: [any NativePlugin],
        defaults: UserDefaults = .standard,
        hooks: SurfaceHooks
    ) {
        self.plugins = plugins
        self.defaults = defaults
        self.hooks = hooks

        claims = [:]
        for plugin in plugins {
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
        installedIDs = Set(storedIDs).intersection(Set(plugins.map(\.id)))

        for plugin in plugins where installedIDs.contains(plugin.id) {
            plugin.activate()
        }
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

    /// Providers contributed by every installed plugin (initial surface
    /// composition at launch).
    var installedProviders: [any BuiltinProvider] {
        plugins
            .filter { installedIDs.contains($0.id) }
            .flatMap(\.providers)
    }

    // MARK: - Lifecycle

    /// Install a plugin: activate it, persist the state, and register its
    /// surfaces. Takes effect immediately — no relaunch. Idempotent.
    func install(_ id: NativePluginID) {
        guard let plugin = plugin(withID: id),
              !installedIDs.contains(id),
              !transitioningIDs.contains(id) else { return }
        plugin.activate()
        installedIDs.insert(id)
        persistInstalledIDs()
        hooks.registerProviders(plugin.providers)
        hooks.refreshSurfaces()
        logger.info("Installed plugin \(id.rawValue)")
    }

    /// Uninstall a plugin, transactionally: `deactivate()` (revert side
    /// effects, cancel in-flight work) must succeed before any state or
    /// surface changes; on a thrown error the plugin stays fully installed
    /// and the error is rethrown for the UI to surface. User data is
    /// retained by design. Idempotent; re-entrant calls are dropped.
    func uninstall(_ id: NativePluginID) async throws {
        guard let plugin = plugin(withID: id),
              installedIDs.contains(id),
              !transitioningIDs.contains(id) else { return }
        transitioningIDs.insert(id)
        defer { transitioningIDs.remove(id) }

        try await plugin.deactivate()

        installedIDs.remove(id)
        persistInstalledIDs()
        hooks.unregisterProviders(plugin.claimedCommands)
        hooks.refreshSurfaces()
        logger.info("Uninstalled plugin \(id.rawValue)")
    }

    /// Forward a config-backup import to every installed plugin so imported
    /// settings apply without a relaunch.
    func reconcileAfterImport() {
        for plugin in plugins where installedIDs.contains(plugin.id) {
            plugin.reconcileAfterImport()
        }
    }

    private func persistInstalledIDs() {
        defaults.set(installedIDs.map(\.rawValue).sorted(), forKey: Self.installStateKey)
    }
}
