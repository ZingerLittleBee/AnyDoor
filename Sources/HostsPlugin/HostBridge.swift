import AppKit
import PluginInterface
import SwiftUI

/// Module-level access point to the host services injected at plugin
/// construction. The module's singletons (`HostsManager.shared`, the editor
/// window controller) and its SwiftUI views reach the host through this
/// bridge rather than threading the services through every initializer —
/// mirroring the ImageConversionPlugin precedent. Set by
/// `HostsNativePlugin.init`.
///
/// Every accessor degrades safely when the bridge is unset (pure unit
/// tests): strings fall back to their raw keys, window tracking no-ops, the
/// helper reads as unavailable, and AppleScript runs fail with a call error.
@MainActor
enum PluginHost {
    private(set) static var services: (any PluginHostServices)?

    static func bootstrap(_ services: any PluginHostServices) {
        Self.services = services
    }

    static func trackRegularWindow(_ window: NSWindow) {
        services?.trackRegularWindow(window)
    }

    static var helper: (any PrivilegedHelperAccess)? {
        services?.privilegedHelper
    }

    static func helperReadiness() -> PrivilegedHelperReadiness {
        helper?.readiness() ?? .unavailable
    }

    /// MainActor entry so nonisolated writers can reach the helper without
    /// carrying the non-Sendable existential across isolation; the write
    /// itself is nonisolated and does not hold the MainActor.
    static func writeHostsFileViaHelper(_ content: String) async throws {
        guard let helper else {
            throw PrivilegedHelperCallError(message: "host services unavailable")
        }
        try await helper.writeHostsFile(content)
    }

    static func runAppleScript(_ source: String) async throws -> String {
        guard let services else {
            throw PrivilegedHelperCallError(message: "host services unavailable")
        }
        return try await services.runAppleScript(source)
    }
}

/// Type-safe view of the shared string catalog's keys this module uses. The
/// entries live in the host's `Localizable.xcstrings` (user story 27:
/// plugin UI localizes through the existing catalog); resolution goes through
/// the host services so language switches apply without a relaunch.
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
        case pluginDescription = "plugin.hosts.description"
        case pluginName = "plugin.hosts.name"
        case pluginUninstallImpact = "plugin.hosts.uninstallImpact"
    }
}

/// Module-local counterpart of the host's `L(_:)`: resolves a catalog key via
/// the host services, applying format arguments in the host's active locale.
@MainActor
func L(_ key: L10n.Key, _ args: CVarArg...) -> String {
    guard let services = PluginHost.services else { return key.rawValue }
    let template = services.localizedString(key.rawValue)
    if args.isEmpty {
        return template
    }
    return String(format: template, locale: services.effectiveLocale, arguments: args)
}
