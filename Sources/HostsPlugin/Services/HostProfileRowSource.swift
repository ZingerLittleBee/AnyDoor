import Foundation
import PluginInterface

/// Surfaces hosts profiles as command-palette root rows — the first
/// descriptor-based `PluginRowSource` (ADR-0007). A row's title is the
/// profile name; committing a row toggles that profile's activation, exactly
/// like the drill-in hosts options (no privileged-write confirmation).
/// Registered through the plugin's palette contributions on install.
@MainActor
final class HostProfileRowSource: PluginRowSource {
    static let sourceID = "hosts.profiles"

    let id = HostProfileRowSource.sourceID
    let sectionTitleKey = "commandPalette.section.hosts"

    private let profilesProvider: @MainActor () -> [HostProfile]
    private let reloadAction: @MainActor () -> Void
    private let setActive: @MainActor (HostProfile, Bool) async -> Void
    private let host: PluginHostContext?

    init(
        host: PluginHostContext? = nil,
        profiles: @escaping @MainActor () -> [HostProfile],
        reload: @escaping @MainActor () -> Void,
        setActive: @escaping @MainActor (HostProfile, Bool) async -> Void
    ) {
        self.host = host
        self.profilesProvider = profiles
        self.reloadAction = reload
        self.setActive = setActive
    }

    /// Re-fetch the profiles once at palette open so the root name search
    /// reflects the current set without a per-keystroke fetch.
    func reload() {
        reloadAction()
    }

    func rows() -> [PluginRowDescriptor] {
        profilesProvider()
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { profile in
                PluginRowDescriptor(
                    id: profile.id.uuidString,
                    title: profile.name,
                    subtitle: profile.isActive ? L(host, .commandPaletteHostsActive) : nil,
                    symbol: profile.isActive ? "checkmark.circle.fill" : "circle",
                    actionLabel: L(host, .commandPaletteActionToggle),
                    commit: .closeThenAct
                )
            }
    }

    func performRow(id: String) async {
        guard let profileID = UUID(uuidString: id),
              let profile = profilesProvider().first(where: { $0.id == profileID })
        else { return }
        await setActive(profile, !profile.isActive)
    }
}
