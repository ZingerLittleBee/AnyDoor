import Foundation
import PluginInterface
import ScriptPluginRuntime

/// The command-palette root row source for one installed Script Plugin.
///
/// Bridges the async, JavaScriptCore-backed `rows()` entry point onto the
/// palette's synchronous `PluginRowSource` contract (ADR-0007): `reload()`
/// (one refresh per palette open) kicks an async `buildRows` and caches the
/// result, and the synchronous `rows()` the palette calls on every keystroke
/// returns that cache. The palette filters by title itself, so the source asks
/// the plugin for its full row set with an empty query — mirroring how the
/// Hosts profile source returns every profile and lets the palette match.
///
/// A committed row runs the plugin's `action` entry point through the runtime;
/// the palette's generic commit path decides whether to close first from the
/// descriptor's own `CommitSemantics`. Markdown Detail navigation is a later
/// ticket and deliberately absent here.
@MainActor
final class ScriptPluginRowSource: PluginRowSource {
    /// One row source per plugin, so its plugin-local id is a constant; the
    /// owner id (which carries the script identity) namespaces it into the
    /// host-scoped `PluginRowSourceKey`.
    static let localID = "rows"

    /// Row action id used until per-action selection arrives with Detail
    /// navigation (ticket 022). The plugin's `action(rowID, actionID)` receives
    /// it as the default primary action.
    static let defaultActionID = "default"

    let id = ScriptPluginRowSource.localID
    let sectionTitleKey: String

    private let scriptID: ScriptPluginID
    private let runtime: ScriptPluginRuntime
    private var cachedRows: [PluginRowDescriptor] = []

    init(scriptID: ScriptPluginID, runtime: ScriptPluginRuntime, sectionTitle: String) {
        self.scriptID = scriptID
        self.runtime = runtime
        self.sectionTitleKey = sectionTitle
    }

    func reload() {
        Task { [weak self] in await self?.refresh() }
    }

    /// Fetch the plugin's rows and cache them. Exposed (beyond the fire-and-
    /// forget `reload()`) so lifecycle tests can await the fetch deterministically
    /// instead of racing the background task.
    func refresh() async {
        cachedRows = (try? await runtime.buildRows(pluginID: scriptID, query: "")) ?? []
    }

    func rows() -> [PluginRowDescriptor] {
        cachedRows
    }

    func performRow(id: String) async {
        _ = try? await runtime.performAction(
            pluginID: scriptID,
            rowID: id,
            actionID: Self.defaultActionID
        )
    }
}
