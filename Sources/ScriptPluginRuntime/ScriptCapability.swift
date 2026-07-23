import Foundation

/// The closed set of host facilities a Script Plugin may declare and use
/// (ADR-0009). The capability list *is* the security model: a capability the
/// manifest does not declare is never injected into the plugin's `JSContext`,
/// so it does not exist for the plugin's code.
///
/// Milestone A granted six; `translate` joined as the seventh (ADR-0009
/// amendment). Refused (and therefore absent here): shell execution,
/// AppleScript, filesystem access, and pasteboard *reading*.
public enum ScriptCapability: String, CaseIterable, Sendable, Hashable {
    /// Network access through the host transport (`anydoor.fetch`).
    case fetch
    /// Plugin-private key-value store, persisted per plugin id (`anydoor.store`).
    case store
    /// User-facing toasts (`anydoor.toast`).
    case toast
    /// Pasteboard writes routed through the host self-write funnel
    /// (`anydoor.copy`), so a plugin's copy never lands in clipboard history.
    case pasteboard
    /// A one-shot delay timer (`anydoor.delay`). JavaScriptCore has no event
    /// loop, so even a timer is a host-granted capability. No repeating timers.
    case delay
    /// Open a URL in the default browser (`anydoor.openURL`). Confined to
    /// `http`/`https` by ``ScriptOpenURLPolicy`` so it cannot reach the
    /// filesystem or launch arbitrary apps.
    case openURL
    /// Translate text into the user's configured target language
    /// (`anydoor.translate`), through the translation service the user set up
    /// in Settings. Declared because it can spend the user's third-party API
    /// quota; the target language is always the user's setting — a plugin
    /// cannot choose the direction.
    case translate

    /// The manifest string authors write. Distinct from `rawValue` only for
    /// `openURL`, whose wire form keeps the conventional casing.
    public var manifestKey: String {
        switch self {
        case .openURL: return "openURL"
        default: return rawValue
        }
    }

    /// Parse a manifest capability string, or `nil` if it names no known
    /// capability (the loader turns that into a typed refusal).
    public init?(manifestKey: String) {
        guard let match = ScriptCapability.allCases.first(where: { $0.manifestKey == manifestKey })
        else { return nil }
        self = match
    }
}
