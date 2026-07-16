import AppKit
import SwiftData

/// A user-facing toast a plugin asks the host to present.
public enum PluginToast: Sendable {
    case success(String)
    case info(String)
    case failure(String)
}

/// The narrow host capabilities a Native Plugin may use.
///
/// This is the only door from a plugin module back into the app (ADR-0005's
/// compiler-enforced boundary): plugins depend on `PluginInterface` alone, so
/// every host facility they need — the shared string catalog, toasts, the
/// activation-policy window tracker, the pasteboard self-write funnel — is
/// expressed here as a capability and implemented by the Core at registry
/// bootstrap. Keep it minimal; a new member needs the same scrutiny as a new
/// `NativePlugin` requirement.
@MainActor
public protocol PluginHostServices: AnyObject {

    /// The shared ModelContainer. A plugin's `@Model` types are part of the
    /// static app schema (ADR-0005), so its stores wire up against this
    /// container in `activate()`.
    var modelContainer: ModelContainer { get }

    /// The host's active locale. Implementations must route the read through
    /// the host's `@Observable` localization state, so reading this (or
    /// `localizedString`) inside a SwiftUI `body` re-renders on a language
    /// switch.
    var effectiveLocale: Locale { get }

    /// Resolves a string-catalog key against the host's active language
    /// (user story 27: plugin UI localizes through the existing catalog).
    /// Returns the key itself when the catalog has no entry.
    func localizedString(_ key: String) -> String

    /// Presents a toast through the host's shared presenter.
    func showToast(_ toast: PluginToast)

    /// Keeps the accessory app reachable while the plugin's window is open
    /// (the host flips to `.regular` activation policy until it closes).
    func trackRegularWindow(_ window: NSWindow)

    /// The host's pasteboard self-write funnel: runs `body` and suppresses
    /// the clipboard-history watcher for the write in one synchronous turn,
    /// so a plugin's own copy never lands in clipboard history.
    func pasteboardSelfWrite(_ body: (NSPasteboard) throws -> Void) rethrows

    /// Runs an AppleScript through the host's runner (Automation permission
    /// handling included) and returns its string result.
    func runAppleScript(_ source: String) async throws -> String

    /// The host's shared privileged helper daemon (Core infrastructure,
    /// amended ADR-0005). See `PrivilegedHelperAccess`.
    var privilegedHelper: any PrivilegedHelperAccess { get }
}
