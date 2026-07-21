import Foundation
import PluginInterface
import ScriptPluginRuntime

/// What committing a command-palette row means, declared in one place.
///
/// `PanelEntry.Source` carries four distinct commit semantics — drill into a
/// second level, raise the in-palette confirmation card, stay open while
/// mutating the query scope, or close the palette and act. These used to be
/// implicit control flow in `CommandPaletteWindowController.commit`: a chain
/// of early-return pattern matches followed by a trailing switch whose
/// already-handled cases degraded to `break // handled above`. A new Source
/// case only surfaced in the trailing switch, silently skipping the stay-open
/// checks. `classify` is exhaustive over Source, so a new case fails to
/// compile until its intent is declared — and the mapping unit-tests without
/// a window.
enum CommandPaletteCommitIntent: Equatable {
    // Stay-open intents — the palette remains visible.
    /// An option parent (Keep Awake, Brightness, Hosts, …): enter its
    /// second-level option list.
    case drillIntoOptions(BuiltinItem)
    /// A drilled-in second-level option: run it, or raise its confirmation
    /// card first when it's destructive (port kill).
    case runOrConfirmOption(id: String)
    /// A root numeric-search port row: raise the kill confirmation card.
    case confirmPortKill(PortRecord)
    /// A dev-tool keyword hint: absorb it into a scope badge and keep typing.
    case enterDevToolScope(DevToolScope)
    /// A Search Template Quicklink: enter argument-input mode.
    case enterQuicklinkArgument(id: UUID)
    /// A plugin row that declared `.stayOpen`: run it through its owning
    /// `PluginRowSource` while the palette remains visible.
    case pluginRowStayOpen(sourceKey: PluginRowSourceKey, rowID: String)
    /// A plugin row that declared `.pushDetail`: push its markdown Detail as a
    /// new palette level while the palette remains visible.
    case pluginRowPushDetail(sourceKey: PluginRowSourceKey, rowID: String, title: String)
    /// A plugin row that declared `.enterArgument`: enter the palette's
    /// Argument input mode bound to this row.
    case pluginRowEnterArgument(sourceKey: PluginRowSourceKey, rowID: String, title: String)
    /// A non-interactive plugin row (loading placeholder / inline error):
    /// committing does nothing and the palette stays open.
    case noAction

    // Close-then-act intents — the palette dismisses first.
    case launchAppShortcut(id: UUID)
    case launchApp(bundleID: String, path: String)
    case toggleBuiltin(BuiltinItem)
    case runBuiltin(BuiltinItem)
    case copyToClipboard(text: String, toast: CopyToast)
    /// A plugin row that declared `.closeThenAct`: dismiss, then run it
    /// through its owning `PluginRowSource` (e.g. toggle a hosts profile).
    case pluginRowCloseThenAct(sourceKey: PluginRowSourceKey, rowID: String)
    /// A plugin row materialized after Argument input: dismiss, then run its
    /// plugin action with the captured argument text.
    case pluginRowRunArgument(sourceKey: PluginRowSourceKey, rowID: String, argument: String)
    /// A plugin row that declared `.openURL`: dismiss, then open the URL.
    case openURL(url: String)
    /// A plugin row that declared `.openURL` with a URL outside the openURL
    /// capability's http/https surface (ADR-0009): dismiss and report a failure
    /// toast rather than opening a `file://` or custom-scheme URL.
    case openURLRejected
    case openQuicklink(id: UUID)
    case openQuicklinkArgument(id: UUID, argument: String)
    /// Close without acting (a submenu/brightness builtin that isn't an
    /// option parent, or a hiddenHotkey row that should never be listed).
    case dismiss

    enum CopyToast: Equatable {
        /// Echo the computed value in the toast (calculator results).
        case calc(display: String)
        /// Generic "copied" confirmation — dev-tool outputs (hashes,
        /// multi-line JSON) are long and unhelpful in a toast.
        case generic
    }

    @MainActor
    static func classify(
        _ source: PanelEntry.Source,
        extensions: CommandPaletteExtensions = .shared
    ) -> CommandPaletteCommitIntent {
        switch source {
        case .builtin(let item):
            // Option parents drill in regardless of kind — Keep Awake and
            // Scheduled Shutdown are toggle-kind but still open their
            // duration list instead of flipping directly.
            if extensions.isOptionParent(item) { return .drillIntoOptions(item) }
            switch item.kind {
            case .toggle: return .toggleBuiltin(item)
            case .action: return .runBuiltin(item)
            case .submenu, .brightnessControl, .hiddenHotkey: return .dismiss
            }
        case .paletteOption(let id):
            return .runOrConfirmOption(id: id)
        case .portRecord(let record):
            return .confirmPortKill(record)
        case .devToolScopeSuggestion(let scope):
            return .enterDevToolScope(scope)
        case .appShortcut(let id):
            return .launchAppShortcut(id: id)
        case .installedApp(let bundleID, let path):
            return .launchApp(bundleID: bundleID, path: path)
        case .calcResult(let result):
            return .copyToClipboard(text: result.copyText, toast: .calc(display: result.display))
        case .devTool(let result):
            return .copyToClipboard(text: result.output, toast: .generic)
        case .conversion(let result):
            return .copyToClipboard(text: result.copyText, toast: .generic)
        case .pluginRow(let sourceKey, let descriptor):
            // Mapped by the descriptor's declared semantics alone (ADR-0007);
            // exhaustive, so a new semantic must declare its intent here.
            switch descriptor.commit {
            case .stayOpen:
                return .pluginRowStayOpen(sourceKey: sourceKey, rowID: descriptor.id)
            case .closeThenAct:
                return .pluginRowCloseThenAct(sourceKey: sourceKey, rowID: descriptor.id)
            case .pushDetail:
                return .pluginRowPushDetail(sourceKey: sourceKey, rowID: descriptor.id, title: descriptor.title)
            case .enterArgument:
                return .pluginRowEnterArgument(sourceKey: sourceKey, rowID: descriptor.id, title: descriptor.title)
            case .openURL(let url):
                // The URL is plugin-supplied; confine it to the openURL
                // capability's http/https surface (ADR-0009) before the palette
                // hands it to the default browser, the same guard the JS
                // capability enforces. A rejected URL fails with a toast, never
                // a silent no-op or a launch outside the declared surface.
                guard let parsed = URL(string: url), ScriptOpenURLPolicy.allows(parsed) else {
                    return .openURLRejected
                }
                return .openURL(url: url)
            case .copy(let text):
                return .copyToClipboard(text: text, toast: .generic)
            case .noAction:
                return .noAction
            case .runArgument(let argument):
                return .pluginRowRunArgument(sourceKey: sourceKey, rowID: descriptor.id, argument: argument)
            }
        case .quicklink(let id):
            return .openQuicklink(id: id)
        case .quicklinkTemplate(let id):
            return .enterQuicklinkArgument(id: id)
        case .quicklinkArgument(let id, let argument):
            return .openQuicklinkArgument(id: id, argument: argument)
        }
    }
}
