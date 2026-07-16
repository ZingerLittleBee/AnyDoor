import AppKit
import SwiftUI

/// Shared module-level access point to the host services injected at plugin
/// construction. Plugin modules' singletons (window controllers, stores) and
/// their SwiftUI views reach the host through this bridge rather than
/// threading the services through every initializer — mirroring the host
/// app's own shared-instance style. Every plugin's `init` calls `bootstrap`;
/// in production they all receive the same `CorePluginHost` instance, and in
/// tests the most recent fixture's host wins.
///
/// Every accessor degrades safely when the bridge is unset (pure unit
/// tests): strings fall back to their raw keys, toasts and window tracking
/// no-op, pasteboard writes go straight to the pasteboard, the privileged
/// helper reads as unavailable, and AppleScript runs fail with a call error.
@MainActor
public enum PluginHost {
    public private(set) static var services: (any PluginHostServices)?

    public static func bootstrap(_ services: any PluginHostServices) {
        Self.services = services
    }

    public static func showToast(_ toast: PluginToast) {
        services?.showToast(toast)
    }

    public static func trackRegularWindow(_ window: NSWindow) {
        services?.trackRegularWindow(window)
    }

    public static func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows {
        if let services {
            try services.pasteboardSelfWrite(body)
        } else {
            try body(NSPasteboard.general)
        }
    }

    public static var helper: (any PrivilegedHelperAccess)? {
        services?.privilegedHelper
    }

    public static func helperReadiness() -> PrivilegedHelperReadiness {
        helper?.readiness() ?? .unavailable
    }

    /// MainActor entry so nonisolated writers can reach the helper without
    /// carrying the non-Sendable existential across isolation; the write
    /// itself is nonisolated and does not hold the MainActor.
    public static func writeHostsFileViaHelper(_ content: String) async throws {
        guard let helper else {
            throw PrivilegedHelperCallError(message: "host services unavailable")
        }
        try await helper.writeHostsFile(content)
    }

    public static func runAppleScript(_ source: String) async throws -> String {
        guard let services else {
            throw PrivilegedHelperCallError(message: "host services unavailable")
        }
        return try await services.runAppleScript(source)
    }

    /// Shared resolver behind every plugin module's typed `L(_:)`: resolves a
    /// string-catalog key via the host services, applying format arguments in
    /// the host's active locale. Falls back to the raw key when the bridge is
    /// unset (pure unit tests) or the catalog has no entry.
    public static func localizedString(_ key: String, arguments: [CVarArg] = []) -> String {
        resolve(key: key, arguments: arguments, services: services)
    }

    /// Pure resolution core, split out so tests can exercise the unset-bridge
    /// fallback and the format path without mutating the shared slot.
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

/// Shared reactive core behind every plugin module's typed `LocalizedText`:
/// a `Text` that re-renders when the host's language changes.
///
/// The reactivity chain: `body` reads `services.effectiveLocale` (and
/// `localizedString`, which reads the host's locale-scoped bundle). The
/// Core's host implementation routes both reads through the `@Observable`
/// `LocalizationManager`, so evaluating this body inside SwiftUI's
/// observation tracking registers a dependency on the language preference —
/// a language switch invalidates and re-renders the view.
@MainActor
public struct PluginLocalizedText: View {
    private let key: String

    public init(key: String) {
        self.key = key
    }

    public var body: some View {
        _ = PluginHost.services?.effectiveLocale
        return Text(PluginHost.localizedString(key))
    }
}
