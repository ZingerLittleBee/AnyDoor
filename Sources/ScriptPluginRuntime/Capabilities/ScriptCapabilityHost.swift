import Foundation
import PluginInterface

/// The host facilities the runtime injects into plugin contexts — the seam the
/// registry (ticket 021) fills with real Core implementations, and that tests
/// fill with spies or a local server.
///
/// Every member is a capability's back end. The runtime injects a capability
/// into a plugin's `JSContext` only when the plugin's manifest declares it, so
/// this bundle being fully populated does not widen any single plugin's reach;
/// the manifest gates what each plugin sees (ADR-0009).
///
/// Toast, pasteboard, and open-URL closures run on the main actor, matching the
/// ADR requirement that capability implementations live there. `delay` is not a
/// member — a one-shot timer needs no host facility and is implemented inside
/// the context against its own queue.
public struct ScriptCapabilityHost: Sendable {
    /// The network transport backing `anydoor.fetch` — the one external boundary.
    public var transport: any ScriptFetchTransport

    /// Directory holding each plugin's private key-value store file. The runtime
    /// derives `<storeDirectory>/<id>.json` per plugin, so the store survives
    /// teardown and reinstall.
    public var storeDirectory: URL

    /// Presents a toast for a plugin (`anydoor.toast`). Carries the originating
    /// plugin id so the host can attribute or route the toast.
    public var presentToast: @MainActor @Sendable (ScriptPluginID, PluginToast) -> Void

    /// Writes plain text to the pasteboard through the host self-write funnel
    /// (`anydoor.copy`), so the write never lands in clipboard history.
    public var writePasteboard: @MainActor @Sendable (String) -> Void

    /// Opens a URL in the default browser (`anydoor.openURL`).
    public var openURL: @MainActor @Sendable (URL) -> Void

    public init(
        transport: any ScriptFetchTransport,
        storeDirectory: URL,
        presentToast: @escaping @MainActor @Sendable (ScriptPluginID, PluginToast) -> Void,
        writePasteboard: @escaping @MainActor @Sendable (String) -> Void,
        openURL: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.transport = transport
        self.storeDirectory = storeDirectory
        self.presentToast = presentToast
        self.writePasteboard = writePasteboard
        self.openURL = openURL
    }
}
