import PluginInterface
import SwiftUI

/// Type-safe view of the shared string catalog's keys this module uses. The
/// entries live in the host's `Localizable.xcstrings` (user story 27:
/// plugin UI localizes through the existing catalog); resolution goes through
/// the plugin instance's host context so language switches apply without a relaunch.
enum L10n {
    enum Key: String, CaseIterable, Sendable {
        case commandPaletteActionToggle = "commandPalette.action.toggle"
        case commandPaletteHostsActive = "commandPalette.hosts.active"
        case commandPaletteHostsEdit = "commandPalette.hosts.edit"
        case commandPaletteSectionHosts = "commandPalette.section.hosts"
        case hostsActionAuthorize = "hosts.action.authorize"
        case hostsActionCancel = "hosts.action.cancel"
        case hostsActionDelete = "hosts.action.delete"
        case hostsActionEdit = "hosts.action.edit"
        case hostsActionOpenDefaultEditor = "hosts.action.openDefaultEditor"
        case hostsActionRename = "hosts.action.rename"
        case hostsActionRestore = "hosts.action.restore"
        case hostsActionRestoreFirstBackup = "hosts.action.restoreFirstBackup"
        case hostsActionSave = "hosts.action.save"
        case hostsDialogDeleteProfile = "hosts.dialog.deleteProfile"
        case hostsDialogRestoreBackup = "hosts.dialog.restoreBackup"
        case hostsErrorBackupFailed = "hosts.error.backupFailed"
        case hostsErrorDeleteFailed = "hosts.error.deleteFailed"
        case hostsErrorLiveReadFailed = "hosts.error.liveReadFailed"
        case hostsErrorNoBackup = "hosts.error.noBackup"
        case hostsFieldName = "hosts.field.name"
        case hostsHelperApproval = "hosts.helper.approval"
        case hostsManagerOpenHelp = "hosts.manager.openHelp"
        case hostsManagerTitle = "hosts.manager.title"
        case hostsProfileCopyName = "hosts.profile.copyName"
        case hostsProfileDisable = "hosts.profile.disable"
        case hostsProfileDuplicate = "hosts.profile.duplicate"
        case hostsProfileEnable = "hosts.profile.enable"
        case hostsProfileNewName = "hosts.profile.newName"
        case hostsSystemOpenHelp = "hosts.system.openHelp"
        case hostsSystemTitle = "hosts.system.title"
        case pluginDescription = "plugin.hosts.description"
        case pluginName = "plugin.hosts.name"
        case pluginUninstallImpact = "plugin.hosts.uninstallImpact"
    }
}

/// Module-typed front for the instance-scoped host resolver.
@MainActor
func L(_ host: PluginHostContext?, _ key: L10n.Key, _ args: CVarArg...) -> String {
    host?.localizedString(key.rawValue, arguments: args) ?? key.rawValue
}

/// Module-typed front for the environment-scoped `PluginLocalizedText`: a `Text`
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
