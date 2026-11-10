import Foundation
import PluginInterface

/// Pure builder for the Hosts drill-in options in the command palette: one
/// checkable row per profile (checkmark = active, committing toggles), plus
/// a System Hosts row and a fixed Open Hosts Manager footer action. Takes
/// already-fetched profiles so it unit tests without singletons.
@MainActor
enum HostsPaletteOptions {
    static let editOptionID = "hosts.edit"
    static let openManagerOptionID = "hosts.openManager"

    static func optionID(for profile: HostProfile) -> String {
        "hosts.\(profile.id.uuidString)"
    }

    static func options(
        profiles: [HostProfile],
        systemHosts: String = "",
        host: PluginHostContext? = nil
    ) -> [PluginRowDescriptor] {
        var options: [PluginRowDescriptor] = profiles.map { profile in
            PluginRowDescriptor(
                id: optionID(for: profile),
                title: profile.name,
                subtitle: contentSummary(for: profile.content),
                symbol: "list.bullet.rectangle",
                actionLabel: L(host, .commandPaletteActionToggle),
                isChecked: profile.isActive,
                commit: .stayOpen
            )
        }
        options.append(PluginRowDescriptor(
            id: editOptionID,
            title: L(host, .hostsSystemTitle),
            subtitle: contentSummary(for: systemHosts),
            symbol: "cpu",
            actionLabel: L(host, .hostsActionEdit),
            commit: .closeThenAct
        ))
        options.append(PluginRowDescriptor(
            id: openManagerOptionID,
            title: L(host, .hostsManagerOpenHelp),
            symbol: "macwindow",
            actionLabel: L(host, .commandPaletteActionOpen),
            footerShortcut: "o",
            commit: .closeThenAct
        ))
        return options
    }

    /// Show mappings rather than comment headers, keeping aliases and IPv6
    /// intact. The row truncates visually; its tooltip retains the full summary.
    static func contentSummary(for content: String) -> String? {
        let mappings = content.components(separatedBy: .newlines).compactMap { line -> String? in
            let mapping = line.prefix { $0 != "#" }
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return mapping.isEmpty ? nil : mapping
        }
        return mappings.isEmpty ? nil : mappings.joined(separator: " · ")
    }

    /// The profile behind a committed option id, or nil for non-profile ids.
    static func profile(for optionID: String, in profiles: [HostProfile]) -> HostProfile? {
        guard optionID.hasPrefix("hosts."),
              let id = UUID(uuidString: String(optionID.dropFirst("hosts.".count)))
        else { return nil }
        return profiles.first { $0.id == id }
    }
}
