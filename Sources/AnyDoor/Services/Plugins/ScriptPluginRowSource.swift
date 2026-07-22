import Foundation
import PluginInterface
import ScriptPluginRuntime

/// The command-palette root row source for one installed Script Plugin.
///
/// Bridges the async, JavaScriptCore-backed entry points onto the palette's
/// synchronous `PluginRowSource` contract (ADR-0007):
///
/// - `reload()` (one refresh per palette open) kicks an async `buildRows` and
///   caches the result; the synchronous `rows()` the palette calls on every
///   keystroke returns that cache. While the first fetch is in flight the source
///   reports `.loading`, and a failed fetch reports `.failed`, so the palette can
///   render a loading placeholder or an inline error row instead of hanging.
/// - `loadDetail(id:cursor:)` builds a committed row's markdown Detail (or its
///   next chunk when the plugin offered a pagination cursor).
/// - `performRow(id:)` / `performRow(id:argument:)` run the plugin's `action`
///   entry point; a failure is reported as a toast (never a silent no-op), while
///   an invocation that lands after the plugin was unloaded is dropped so a
///   just-uninstalled plugin cannot flash a spurious failure.
///
/// The palette filters by title itself, so the source asks the plugin for its
/// full row set with an empty query — mirroring how the Hosts profile source
/// returns every profile and lets the palette match.
@MainActor
final class ScriptPluginRowSource: PluginRowSource {
    /// One row source per plugin, so its plugin-local id is a constant; the
    /// owner id (which carries the script identity) namespaces it into the
    /// host-scoped `PluginRowSourceKey`.
    static let localID = "rows"

    /// Action id passed to the plugin's `action(rowID, actionID)` for a row's
    /// primary action. Milestone A rows have a single primary action.
    static let defaultActionID = "default"

    let id = ScriptPluginRowSource.localID
    let sectionTitleKey: String

    private let scriptID: ScriptPluginID
    private let runtime: ScriptPluginRuntime
    /// Whether a failed build surfaces the error's own detail (Dev Plugin) or the
    /// plain generic inline string (a normally installed plugin). See
    /// ``ScriptPluginErrorPresentation`` (ticket 023).
    private let surfacesErrorDetail: Bool
    private var cachedRows: [PluginRowDescriptor] = []
    private var currentLoadState: PluginRowLoadState = .loading
    /// Nudges a visible palette to recompute its rows once an async fetch lands.
    private let onRowsChanged: @MainActor () -> Void
    /// Presents a failure toast when a committed row action throws.
    private let onActionError: @MainActor (ScriptPluginError) -> Void

    init(
        scriptID: ScriptPluginID,
        runtime: ScriptPluginRuntime,
        sectionTitle: String,
        surfacesErrorDetail: Bool = false,
        onRowsChanged: @escaping @MainActor () -> Void = {},
        onActionError: @escaping @MainActor (ScriptPluginError) -> Void = { _ in }
    ) {
        self.scriptID = scriptID
        self.runtime = runtime
        self.sectionTitleKey = sectionTitle
        self.surfacesErrorDetail = surfacesErrorDetail
        self.onRowsChanged = onRowsChanged
        self.onActionError = onActionError
    }

    var loadState: PluginRowLoadState { currentLoadState }

    func reload() {
        Task { [weak self] in await self?.refresh() }
    }

    /// Fetch the plugin's rows and cache them, updating the load state. Exposed
    /// (beyond the fire-and-forget `reload()`) so tests can await the fetch
    /// deterministically instead of racing the background task. A successful
    /// fetch clears any prior error; a failure leaves the cache empty and
    /// records the failure so the palette shows an inline error row.
    func refresh() async {
        do {
            cachedRows = try await runtime.buildRows(pluginID: scriptID, query: "")
            currentLoadState = .ready
        } catch {
            cachedRows = []
            currentLoadState = .failed(ScriptPluginErrorPresentation.message(
                for: error,
                surfacesDetail: surfacesErrorDetail,
                generic: L(.commandPalettePluginRowError)
            ))
        }
        onRowsChanged()
    }

    func rows() -> [PluginRowDescriptor] {
        cachedRows
    }

    /// Force the source into a failed state with a caller-supplied message, used
    /// when a Dev Plugin reload refuses at the manifest boundary (before any
    /// runtime invocation can report it). Clears the cached rows and nudges the
    /// visible palette to redraw.
    func reportLoadFailure(_ message: String) {
        cachedRows = []
        currentLoadState = .failed(message)
        onRowsChanged()
    }

    func loadDetail(id: String, cursor: String?) async -> PluginRowDetailResult? {
        do {
            let chunk = try await runtime.buildDetail(pluginID: scriptID, rowID: id, cursor: cursor)
            return .markdown(chunk.markdown, more: chunk.more, actions: chunk.actions)
        } catch {
            return .failure(ScriptPluginErrorPresentation.message(
                for: error,
                surfacesDetail: surfacesErrorDetail,
                generic: L(.commandPaletteDetailFailed)
            ))
        }
    }

    func loadDetailAction(id: String, actionID: String) async -> PluginRowDetailResult? {
        guard runtime.isLoaded(scriptID) else { return nil }
        do {
            let chunk = try await runtime.buildDetailAction(
                pluginID: scriptID, rowID: id, actionID: actionID)
            return .markdown(chunk.markdown, more: chunk.more, actions: chunk.actions)
        } catch {
            return .failure(ScriptPluginErrorPresentation.message(
                for: error,
                surfacesDetail: surfacesErrorDetail,
                generic: L(.commandPaletteDetailFailed)
            ))
        }
    }

    func loadList(id listID: String, query: String) async -> PluginRowListResult? {
        // Drop-after-unload guard (mirrors runAction): a `pushList` row committed
        // just before uninstall can reach here after the context was torn down.
        // Report nothing so the palette — which has already popped to root on the
        // uninstall recomposition — never repopulates a stale list.
        guard runtime.isLoaded(scriptID) else { return nil }
        do {
            let rows = try await runtime.buildList(pluginID: scriptID, listID: listID, query: query)
            return .rows(rows)
        } catch {
            // A missing `list` handler surfaces `entryPointMissing`, which lands
            // here as an inline error row — a `pushList` row with no backing list
            // fails visibly rather than silently.
            return .failure(ScriptPluginErrorPresentation.message(
                for: error,
                surfacesDetail: surfacesErrorDetail,
                generic: L(.commandPalettePluginRowError)
            ))
        }
    }

    func performRow(id: String) async {
        await runAction(rowID: id, argument: nil)
    }

    func performRow(id: String, argument: String) async {
        await runAction(rowID: id, argument: argument)
    }

    private func runAction(rowID: String, argument: String?) async {
        // A row committed just before uninstall can dispatch here after the
        // context was torn down; drop it so a just-uninstalled plugin never
        // flashes a spurious failure toast (021-verifier note).
        guard runtime.isLoaded(scriptID) else { return }
        do {
            _ = try await runtime.performAction(
                pluginID: scriptID,
                rowID: rowID,
                actionID: Self.defaultActionID,
                argument: argument
            )
            // Rebuild the cached rows so state a stayOpen action just changed
            // (a toggle's checkmark or badge) re-renders immediately instead of
            // waiting for the next palette open. The cache is replaced only
            // when the fetch lands, so nothing flickers meanwhile.
            await refresh()
        } catch let error as ScriptPluginError {
            // The plugin was unloaded mid-flight — not a plugin failure.
            if case .notLoaded = error { return }
            onActionError(error)
        } catch {
            onActionError(.invocationFailed(error.localizedDescription))
        }
    }
}
