import PluginInterface
import SwiftUI

/// Type-safe view of the shared string catalog's keys this module uses. The
/// entries live in the host's `Localizable.xcstrings` (user story 27:
/// plugin UI localizes through the existing catalog); resolution goes through
/// `PluginHost.localizedString` so language switches apply without a relaunch.
enum L10n {
    enum Key: String, CaseIterable, Sendable {
        case commandPaletteActionToggle = "commandPalette.action.toggle"
        case commandPaletteHostsActive = "commandPalette.hosts.active"
        case commandPaletteHostsEdit = "commandPalette.hosts.edit"
        case commandPaletteSectionHosts = "commandPalette.section.hosts"
        case hostsProfileCopyName = "hosts.profile.copyName"
        case hostsProfileDisable = "hosts.profile.disable"
        case hostsProfileDuplicate = "hosts.profile.duplicate"
        case hostsProfileEnable = "hosts.profile.enable"
        case hostsUninstallWriteFailed = "hosts.uninstall.writeFailed"
        case pluginDescription = "plugin.hosts.description"
        case pluginName = "plugin.hosts.name"
        case pluginUninstallImpact = "plugin.hosts.uninstallImpact"
    }
}

/// Module-typed front for the shared resolver (`PluginHost.localizedString`).
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    PluginHost.localizedString(key.rawValue, arguments: args)
}

/// Module-typed front for the shared reactive `PluginLocalizedText`: a `Text`
/// that re-renders on a host language switch.
@MainActor
struct LocalizedText: View {
    private let key: L10n.Key

    init(_ key: L10n.Key) {
        self.key = key
    }

    var body: some View {
        PluginLocalizedText(key: key.rawValue)
    }
}
