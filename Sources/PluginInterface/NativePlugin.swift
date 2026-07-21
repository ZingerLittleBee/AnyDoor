import SwiftData

/// Stable identity of a Native Plugin. The raw value is persisted (install
/// state, config backup) and must never change once shipped.
public struct NativePluginID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A first-party feature module the user installs or uninstalls as one unit.
///
/// A Native Plugin's code always ships with the app (ADR-0005): Install is a
/// logical state change, never a download. While uninstalled the plugin is
/// invisible everywhere — it contributes no commands, no panel rows, no
/// palette entries, no settings, and requests no permissions. Everything not
/// claimed by a Native Plugin is the Core, which may enumerate plugin-claimed
/// commands through the shared catalog but never names a plugin in its
/// control flow (ADR-0007).
@MainActor
public protocol NativePlugin: AnyObject {

    // MARK: Identity

    /// Stable identity, persisted in the install-state store and in backups.
    var id: NativePluginID { get }

    /// User-facing name, resolved against the active app language.
    var localizedName: String { get }

    /// One-sentence user-facing description for the Plugins settings tab.
    var localizedDescription: String { get }

    /// User-facing description of what an Uninstall does or leaves behind
    /// (e.g. "active hosts entries stay in the hosts file"), shown in the
    /// uninstall confirmation. `nil` when uninstalling only removes surfaces.
    var localizedUninstallImpact: String? { get }

    // MARK: Claims

    /// The built-in commands this plugin Claims. A Claim is exclusive: every
    /// `BuiltinItem` case is owned by exactly one Native Plugin or by the
    /// Core (ADR-0006), and the catalog invariant tests enforce it.
    var claimedCommands: Set<BuiltinItem> { get }

    // MARK: Contributions (present only while installed)

    /// One provider per actionable (toggle/action-kind) claimed command.
    var providers: [any BuiltinProvider] { get }

    /// Claimed commands that drill into a second-level option list in the
    /// command palette instead of acting directly.
    var paletteOptionParents: Set<BuiltinItem> { get }

    /// Builds the current second-level rows for one of this plugin's
    /// registered palette option parents.
    func paletteOptions(for parent: BuiltinItem) async -> [PluginRowDescriptor]

    /// Runs the action behind a committed second-level option (mirroring
    /// `PluginRowSource.performRow`): the host routes the option back by its
    /// descriptor id, so its control flow never names the plugin.
    func performPaletteOption(parent: BuiltinItem, id: String) async

    /// Root-level command-palette row sources (e.g. hosts profile rows),
    /// descriptor-based per ADR-0007.
    var paletteRowSources: [any PluginRowSource] { get }

    /// The menu-panel popover contributed for a claimed submenu command, or
    /// nil when that command has no popover.
    func panelPopover(for command: BuiltinItem) -> PluginPanelPopover?

    /// Context-menu actions this plugin contributes for a clipboard-history
    /// entry with the given payload. Called at menu-build time on the main
    /// actor; must stay cheap, synchronous, and disk-free.
    func clipboardActions(for payload: PluginClipboardPayload) -> [PluginClipboardAction]

    /// Runs a committed clipboard action, routed back by descriptor id — the
    /// host's control flow never names the plugin behind an action. Loading
    /// the payload and reporting a load failure belong here.
    func performClipboardAction(
        id: String,
        payload: PluginClipboardPayload,
        context: PluginClipboardActionContext
    ) async

    /// SwiftData model types owned by this plugin. Collected once at
    /// ModelContainer creation — the schema stays static regardless of
    /// install state (ADR-0005), which is what keeps user data retained
    /// across Uninstall and restored by a later Install. Nonisolated and
    /// static because the host builds the ModelContainer before any
    /// MainActor plugin instance exists.
    nonisolated static var modelSchemaTypes: [any PersistentModel.Type] { get }

    // MARK: Migration

    /// Whether existing user data shows this plugin was in use before the
    /// plugin split. Evaluated once by the versioned launch migration to
    /// auto-Install the plugin for upgrading users so nobody loses a feature
    /// they were using.
    func hasUsageTrace(in context: ModelContext) throws -> Bool

    // MARK: Lifecycle

    /// Called when the plugin is Installed, and on every launch while
    /// installed, before its surfaces register.
    func activate()

    /// Called on Uninstall, before any surface is unregistered. Must cancel
    /// the plugin's in-flight work and release shared host resources it
    /// holds (e.g. the privileged helper); it must not surprise the user
    /// with system mutations or authorization prompts (ADR-0005 addendum
    /// 2026-07-17). Uninstall is transactional: a thrown error aborts the
    /// uninstall and leaves the plugin fully installed — there is no
    /// half-uninstalled state.
    func deactivate() async throws

    /// Called after a config-backup import so the plugin re-reads imported
    /// settings and refreshes its surfaces without a relaunch.
    func reconcileAfterImport()
}

// Default-empty contributions and no-op hooks keep the next plugin
// mechanical: a plugin implements only the surfaces it actually has.
// `deactivate` deliberately has no default — cancelling in-flight work and
// releasing shared resources must be a conscious per-plugin decision.
extension NativePlugin {
    public var localizedUninstallImpact: String? { nil }

    public var paletteOptionParents: Set<BuiltinItem> { [] }

    public func paletteOptions(for parent: BuiltinItem) async -> [PluginRowDescriptor] { [] }

    public func performPaletteOption(parent: BuiltinItem, id: String) async {}

    public var paletteRowSources: [any PluginRowSource] { [] }

    public func panelPopover(for command: BuiltinItem) -> PluginPanelPopover? { nil }

    public func clipboardActions(for payload: PluginClipboardPayload) -> [PluginClipboardAction] { [] }

    public func performClipboardAction(
        id: String,
        payload: PluginClipboardPayload,
        context: PluginClipboardActionContext
    ) async {}

    public nonisolated static var modelSchemaTypes: [any PersistentModel.Type] { [] }

    public func activate() {}

    public func reconcileAfterImport() {}
}
