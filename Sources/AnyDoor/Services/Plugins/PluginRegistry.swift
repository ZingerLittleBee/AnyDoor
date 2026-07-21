import Foundation
import Observation
import PluginInterface
import SwiftData

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

    /// The installed Native Plugin ids. Backed by the kind-agnostic
    /// `PluginLifecycleCore` install-state set, mapped into the typed identity.
    var installedIDs: Set<NativePluginID> {
        Set(core.installedIDStrings.map(NativePluginID.init(rawValue:)))
    }

    @ObservationIgnored private let panelStore: PanelStore
    @ObservationIgnored private let paletteExtensions: CommandPaletteExtensions
    @ObservationIgnored private let hotkeyCoordinator: HotkeyCoordinator
    @ObservationIgnored private var claims: [BuiltinItem: NativePluginID] = [:]
    @ObservationIgnored private var isBootstrapped = false
    /// The shared, kind-agnostic lifecycle engine. This registry is its
    /// Native-kind host: it owns claims, providers, and hotkey conflicts, and
    /// feeds the core opaque id strings through `AnyPluginLifecycleHost`.
    @ObservationIgnored private var core: PluginLifecycleCore!

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
        self.core = PluginLifecycleCore(
            host: self,
            installStateKey: Self.installStateKey,
            refreshCommandPalette: refreshCommandPalette
        )
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
        core.defaults = defaults

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

        // The core reads the persisted set, activates each installed plugin
        // before marking it installed, and marks it — surface composition below
        // is batched because launch has no suspension point and no plugin
        // surface is visible yet.
        core.loadAndActivateInstalled()

        let installedPlugins = plugins.filter { core.contains($0.id.rawValue) }
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
        core.contains(id.rawValue)
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
        return core.contains(owner.rawValue)
    }

    /// The full catalog minus uninstalled plugins' claims — the installed-set
    /// input to hotkey snapshot compilation.
    var availableCommands: Set<BuiltinItem> {
        var commands = Set(BuiltinItem.allCases)
        for plugin in plugins where !core.contains(plugin.id.rawValue) {
            commands.subtract(plugin.claimedCommands)
        }
        return commands
    }

    /// The panel popover for a claimed submenu command, or nil when the Core
    /// owns the command or its plugin is not installed — an uninstalled
    /// plugin's popover must never mount.
    func panelPopover(for command: BuiltinItem) -> PluginPanelPopover? {
        guard let owner = claims[command],
              core.contains(owner.rawValue),
              let plugin = plugin(withID: owner) else { return nil }
        return plugin.panelPopover(for: command)
    }

    /// Context-menu actions installed plugins contribute for a
    /// clipboard-history entry, each paired with its owner for commit
    /// routing. An uninstalled plugin contributes nothing.
    func clipboardActions(
        for payload: PluginClipboardPayload
    ) -> [(owner: NativePluginID, action: PluginClipboardAction)] {
        plugins
            .filter { core.contains($0.id.rawValue) }
            .flatMap { plugin in
                plugin.clipboardActions(for: payload).map { (plugin.id, $0) }
            }
    }

    /// Perform a committed clipboard action. Re-checks install state so a
    /// menu built just before an uninstall landed can never reach the plugin.
    func performClipboardAction(
        pluginID: NativePluginID,
        actionID: String,
        payload: PluginClipboardPayload,
        context: PluginClipboardActionContext
    ) async {
        guard core.contains(pluginID.rawValue),
              let plugin = plugin(withID: pluginID) else { return }
        await plugin.performClipboardAction(id: actionID, payload: payload, context: context)
    }

    // MARK: - Lifecycle

    /// Install a plugin: activate it, persist the state, and register its
    /// surfaces. Takes effect immediately — no relaunch. Idempotent. The
    /// transactional machinery lives in `PluginLifecycleCore`; the Native-kind
    /// hooks below supply the claims, providers, and hotkey conflicts.
    func install(_ id: NativePluginID) {
        core.install(id.rawValue)
    }

    /// Uninstall a plugin, transactionally: `deactivate()` (release shared
    /// resources, cancel in-flight work) must succeed before any state or
    /// surface changes; on a thrown error the plugin stays fully installed
    /// and the error is rethrown for the UI to surface. User data is
    /// retained by design. Idempotent; a concurrent transition is reported.
    func uninstall(_ id: NativePluginID) async throws {
        try await core.uninstall(id.rawValue)
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
    /// reality. The core returns every failed transition; this layer maps them
    /// into the Native-kind error and throws.
    func reconcileAfterImport() async throws {
        let failures = await core.reconcileAfterImport()
        guard !failures.isEmpty else { return }
        throw PluginImportReconciliationError(
            failures: failures.map { failure in
                importFailure(forID: failure.idString, error: failure.error)
            }
        )
    }

    private func importFailure(
        forID idString: String,
        error: any Error
    ) -> PluginImportFailure {
        PluginImportFailure(
            pluginID: NativePluginID(rawValue: idString),
            pluginName: plugin(withRawID: idString)?.localizedName ?? idString,
            errorDescription: error.localizedDescription
        )
    }

    private func plugin(withRawID idString: String) -> (any NativePlugin)? {
        plugins.first { $0.id.rawValue == idString }
    }
}

// MARK: - AnyPluginLifecycleHost (the Native-kind driver of the shared core)

/// The Native-Plugin implementation of the kind-agnostic lifecycle hooks. Every
/// method resolves the opaque id string back to the typed plugin and applies
/// the Native-specific behavior — claim-derived providers, palette
/// contributions, retained-hotkey conflict resolution — that the core must not
/// know about.
extension PluginRegistry: AnyPluginLifecycleHost {
    func lifecyclePluginIDs() -> [String] {
        plugins.map(\.id.rawValue)
    }

    func activateLifecyclePlugin(idString: String) {
        plugin(withRawID: idString)?.activate()
    }

    func deactivateLifecyclePlugin(idString: String) async throws {
        guard let plugin = plugin(withRawID: idString) else { return }
        try await plugin.deactivate()
    }

    func prepareLifecycleInstall(idString: String) {
        guard let plugin = plugin(withRawID: idString) else { return }
        hotkeyCoordinator.resolveRetainedPluginHotkeyConflicts(
            for: plugin.claimedCommands,
            activeCommands: availableCommands
        )
    }

    func registerLifecycleSurfaces(idString: String) {
        guard let plugin = plugin(withRawID: idString) else { return }
        panelStore.registerProviders(plugin.providers)
        paletteExtensions.registerContributions(of: plugin)
    }

    func unregisterLifecycleSurfaces(idString: String) {
        guard let plugin = plugin(withRawID: idString) else { return }
        panelStore.unregisterProviders(for: plugin.claimedCommands)
        paletteExtensions.unregisterContributions(of: plugin)
    }

    func publishLifecycleSurfaces() {
        panelStore.rebuild()
        hotkeyCoordinator.refresh()
    }

    func reconcileLifecycleImport(idString: String) {
        plugin(withRawID: idString)?.reconcileAfterImport()
    }

    func lifecycleTransitionInProgressError(idString: String) -> any Error {
        PluginTransitionInProgressError(
            pluginID: NativePluginID(rawValue: idString),
            message: L(.pluginsTransitionInProgress)
        )
    }
}
