import PluginInterface
import SwiftData
import SwiftUI

/// The Hosts feature as a Native Plugin (ADR-0005 pilot: heavy system side
/// effects — privileged `/etc/hosts` writes through the shared helper daemon,
/// an editor window, a panel popover, and palette contributions). The module
/// touches the host only through `PluginHostServices`; the privileged helper
/// daemon itself stays Core infrastructure (amended ADR-0005) and is reached
/// through the host's `privilegedHelper` capability.
@MainActor
public final class HostsNativePlugin: NativePlugin {

    /// Stable persisted identity; never change once shipped.
    public static let pluginID = NativePluginID(rawValue: "hosts")

    public let id = HostsNativePlugin.pluginID

    /// Captured at construction (rather than read from the module bridge) so
    /// lifecycle calls stay bound to this instance's host in tests.
    private let host: any PluginHostServices
    private let manager: HostsManager
    private let profileRowSource: HostProfileRowSource

    public convenience init(host: any PluginHostServices) {
        self.init(host: host, manager: .shared)
    }

    /// Test entry point: inject a manager wired to the sanctioned writer
    /// double (`MockHostsWriter`) so the transactional uninstall path can be
    /// exercised without touching the real system.
    init(host: any PluginHostServices, manager: HostsManager) {
        PluginHost.bootstrap(host)
        self.host = host
        self.manager = manager
        self.profileRowSource = HostProfileRowSource(
            profiles: { manager.profiles },
            reload: { manager.reload() },
            setActive: { await manager.setActive($0, $1) }
        )
    }

    public var localizedName: String { L(.pluginName) }

    public var localizedDescription: String { L(.pluginDescription) }

    public var localizedUninstallImpact: String? { L(.pluginUninstallImpact) }

    public let claimedCommands: Set<BuiltinItem> = [.hostsManager]

    /// `.hostsManager` is submenu-kind: it opens a popover instead of
    /// toggling or running, so the plugin registers no provider.
    public let providers: [any BuiltinProvider] = []

    // MARK: - Palette

    public let paletteOptionParents: Set<BuiltinItem> = [.hostsManager]

    public func paletteOptions(for parent: BuiltinItem) async -> [PluginRowDescriptor] {
        guard parent == .hostsManager else { return [] }
        manager.reload()
        return HostsPaletteOptions.options(profiles: manager.profiles)
    }

    public func performPaletteOption(parent: BuiltinItem, id: String) async {
        guard parent == .hostsManager else { return }
        if id == HostsPaletteOptions.editOptionID {
            HostsEditorWindowController.shared.show(manager: manager)
            return
        }
        guard let profile = HostsPaletteOptions.profile(for: id, in: manager.profiles) else { return }
        await manager.setActive(profile, !profile.isActive)
    }

    public var paletteRowSources: [any PluginRowSource] { [profileRowSource] }

    // MARK: - Panel & window

    public func panelPopover(for command: BuiltinItem) -> PluginPanelPopover? {
        guard command == .hostsManager else { return nil }
        let manager = self.manager
        return PluginPanelPopover(
            needsKeyFocus: false,
            makeContent: { context in
                AnyView(HostsManagerPopoverView(
                    manager: manager,
                    onHoverChange: context.onHoverChange,
                    onEdit: {
                        context.dismissPopover()
                        HostsEditorWindowController.shared.show(manager: manager)
                        context.closePanel()
                    },
                    onClose: { context.dismissPopover() }
                ))
            },
            // Mounting happens from already-loaded state; this refresh (and
            // the host's remount) picks up profile/system-hosts changes
            // without blocking the hover crossing on the synchronous
            // SwiftData fetch + /etc/hosts read.
            refresh: { manager.refresh() }
        )
    }

    public func presentWindow(for command: BuiltinItem) {
        guard command == .hostsManager else { return }
        HostsEditorWindowController.shared.show(manager: manager)
    }

    // MARK: - Data & migration

    /// Nonisolated so the host can register the plugin's schema when building
    /// the ModelContainer, before any MainActor plugin instance exists
    /// (ADR-0005: the schema is static regardless of install state).
    public nonisolated static var modelSchemaTypes: [any PersistentModel.Type] {
        [HostProfile.self]
    }

    public var modelTypes: [any PersistentModel.Type] { Self.modelSchemaTypes }

    /// Usage trace (ADR-0005): host profile rows exist OR the privileged
    /// helper daemon is registered — the helper check prevents a ghost
    /// daemon with no managing UI.
    public func hasUsageTrace(in context: ModelContext) throws -> Bool {
        if try context.fetchCount(FetchDescriptor<HostProfile>()) > 0 {
            return true
        }
        return host.privilegedHelper.readiness() != .unavailable
    }

    // MARK: - Lifecycle

    public func activate() {
        // Registration is an install-time act (user story 14: an uninstalled
        // plugin requests no permissions), so it lives here rather than in
        // the manager's bootstrap. Cheap when already registered.
        _ = host.privilegedHelper.ensureRegistered()
        manager.bootstrap(modelContainer: host.modelContainer)
    }

    /// Uninstall (transactional): deactivate every active profile through
    /// the normal writer path, then release the shared helper daemon (the
    /// Core keeps it while forced Scheduled Shutdown still needs it), then
    /// close the editor window. A failed write or a cancelled administrator
    /// authorization throws before any state changed, leaving the plugin
    /// fully installed. Profile rows and hosts backups are retained.
    public func deactivate() async throws {
        try await manager.deactivateAllForUninstall()
        try host.privilegedHelper.releaseIfUnneeded()
        HostsEditorWindowController.shared.closeForUninstall()
    }

    public func reconcileAfterImport() {
        manager.reload()
    }
}
