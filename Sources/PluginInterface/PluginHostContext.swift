import AppKit
import SwiftUI

/// Instance-scoped access to the narrow host capabilities granted to a Native
/// Plugin. Each plugin constructs one context and passes it to its services,
/// controllers, and root views, so separate plugin instances and test fixtures
/// cannot overwrite one another's host.
@MainActor
public final class PluginHostContext {
    private let services: any PluginHostServices

    public init(services: any PluginHostServices) {
        self.services = services
    }

    public var effectiveLocale: Locale { services.effectiveLocale }

    public func showToast(_ toast: PluginToast) {
        services.showToast(toast)
    }

    public func trackRegularWindow(_ window: NSWindow) {
        services.trackRegularWindow(window)
    }

    public func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        try services.pasteboardSelfWrite(body)
    }

    public var helper: any PrivilegedHelperAccess { services.privilegedHelper }

    public func helperReadiness() -> PrivilegedHelperReadiness {
        services.privilegedHelper.readiness()
    }

    public func writeHostsFileViaHelper(_ content: String) async throws {
        try await services.privilegedHelper.writeHostsFile(content)
    }

    public func runAppleScript(_ source: String) async throws -> String {
        try await services.runAppleScript(source)
    }

    public func localizedString(_ key: String, arguments: [CVarArg] = []) -> String {
        Self.resolve(key: key, arguments: arguments, services: services)
    }

    /// Pure resolution core used by localization tests and fallback paths.
    static func resolve(
        key: String,
        arguments: [CVarArg],
        services: (any PluginHostServices)?
    ) -> String {
        guard let services else { return key }
        let template = services.localizedString(key)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: services.effectiveLocale, arguments: arguments)
    }
}

private struct PluginHostContextKey: EnvironmentKey {
    static let defaultValue: PluginHostContext? = nil
}

public extension EnvironmentValues {
    var pluginHostContext: PluginHostContext? {
        get { self[PluginHostContextKey.self] }
        set { self[PluginHostContextKey.self] = newValue }
    }
}

public extension View {
    func pluginHostContext(_ context: PluginHostContext) -> some View {
        environment(\.pluginHostContext, context)
    }
}

/// A plugin-localized `Text` that follows the host's active language. The root
/// plugin view supplies its instance context through the SwiftUI environment;
/// pure view tests without a host fall back to the raw catalog key.
@MainActor
public struct PluginLocalizedText: View {
    @Environment(\.pluginHostContext) private var host
    private let key: String

    public init(key: String) {
        self.key = key
    }

    public var body: some View {
        _ = host?.effectiveLocale
        return Text(host?.localizedString(key) ?? key)
    }
}
