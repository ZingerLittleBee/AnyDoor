import Foundation
import PluginInterface

/// Pure builder for the Hosts drill-in options in the command palette: one
/// checkable row per profile (checkmark = active, committing toggles), plus
/// an always-present "Edit hosts…" row that opens the editor window. Takes
/// already-fetched profiles so it unit tests without singletons.
@MainActor
enum HostsPaletteOptions {
    static let editOptionID = "hosts.edit"

    static func optionID(for profile: HostProfile) -> String {
        "hosts.\(profile.id.uuidString)"
    }

    static func options(
        profiles: [HostProfile],
        host: PluginHostContext? = nil
    ) -> [PluginRowDescriptor] {
        var options: [PluginRowDescriptor] = profiles.map { profile in
            PluginRowDescriptor(
                id: optionID(for: profile),
                title: profile.name,
                symbol: "list.bullet.rectangle",
                isChecked: profile.isActive,
                commit: .closeThenAct
            )
        }
        options.append(PluginRowDescriptor(
            id: editOptionID,
            title: L(host, .commandPaletteHostsEdit),
            symbol: "pencil",
            commit: .closeThenAct
        ))
        return options
    }

    /// The profile behind a committed option id, or nil for non-profile ids.
    static func profile(for optionID: String, in profiles: [HostProfile]) -> HostProfile? {
        guard optionID.hasPrefix("hosts."),
              let id = UUID(uuidString: String(optionID.dropFirst("hosts.".count)))
        else { return nil }
        return profiles.first { $0.id == id }
    }
}
