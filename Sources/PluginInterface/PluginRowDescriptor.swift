import Foundation

/// Host-scoped identity for a plugin-contributed palette row source.
///
/// A plugin only declares its local `PluginRowSource.id`. Core combines that
/// value with the owning plugin's stable identity at registration time, so
/// unrelated plugins may use the same local source id without replacing or
/// routing to each other.
public struct PluginRowSourceKey: Hashable, Sendable {
    public let pluginID: NativePluginID
    public let localID: String

    public init(pluginID: NativePluginID, localID: String) {
        self.pluginID = pluginID
        self.localID = localID
    }
}

/// A command-palette row contributed by a Native Plugin (ADR-0007).
///
/// Plugins never build `PanelEntry` — that type and its `Source` payloads are
/// Core-internal. A plugin declares its rows as pure descriptors instead;
/// Core maps each descriptor onto the generic `Source.pluginRow` case and
/// routes a committed row back to its owning `PluginRowSource` by its
/// host-scoped key, so
/// Core control flow never names the plugin behind a row.
public struct PluginRowDescriptor: Hashable, Sendable {
    /// What committing the row means to the palette. The commit-intent
    /// classifier maps a plugin row by this declared value alone.
    ///
    /// The first six cases are author-facing — a plugin declares one per row.
    /// The last two (`noAction`, `runArgument`) are host-synthesized for the
    /// rows the palette builds itself (a loading/error status row, and the row
    /// materialized after Argument input), never decoded from a plugin package.
    public enum CommitSemantics: Hashable, Sendable {
        /// The palette dismisses first, then the row's plugin action runs
        /// (e.g. toggling a hosts profile).
        case closeThenAct
        /// The palette stays open while the row's plugin action runs.
        case stayOpen
        /// Push the row's markdown Detail as a new palette navigation level.
        case pushDetail
        /// Close the palette, then open this URL in the default browser.
        case openURL(String)
        /// Close the palette, then copy this text through the host self-write
        /// funnel (so a plugin copy never lands in clipboard history).
        case copy(String)
        /// Enter the palette's Argument input mode; the entered text is passed
        /// to the row's plugin action.
        case enterArgument
        /// A non-interactive row (a loading placeholder or an inline error).
        /// Committing it does nothing and keeps the palette open. Host-only.
        case noAction
        /// Run the row's plugin action with a captured Argument-input string.
        /// Synthesized by the host once the user submits the argument; not a
        /// value a plugin declares. Host-only.
        case runArgument(String)
    }

    /// Stable identity within the owning row source; commit routes back
    /// through `PluginRowSource.performRow(id:)` with this value.
    public let id: String
    public let title: String
    public let subtitle: String?
    /// SF Symbol name.
    public let symbol: String
    /// Localized label for the row's primary action, shown in the palette's
    /// footer (e.g. "Toggle"). Nil falls back to the host's generic label.
    public let actionLabel: String?
    /// Whether the row shows a leading checkmark (second-level option lists
    /// only — e.g. the active hosts profile, the current color format).
    public let isChecked: Bool
    public let commit: CommitSemantics

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        actionLabel: String? = nil,
        isChecked: Bool = false,
        commit: CommitSemantics
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.actionLabel = actionLabel
        self.isChecked = isChecked
        self.commit = commit
    }
}

/// The load state of a row source whose rows are produced asynchronously
/// (a Script Plugin building rows off its JavaScript queue). Synchronous
/// sources (hosts profiles) stay `.ready`; the palette renders a loading
/// placeholder or an inline error row for the other two states so a slow or
/// broken plugin degrades visibly instead of hanging (user story 9).
public enum PluginRowLoadState: Sendable, Equatable {
    /// `rows()` is authoritative.
    case ready
    /// A build is in flight and no rows are cached yet — show a loading row.
    case loading
    /// The last build failed (message carried) — show an inline error row.
    case failed(String)
}

/// The result of building a row's markdown Detail: the markdown to render, or
/// a failure message to show inline. `nil` from `loadDetail` means the source
/// has no Detail for that row at all.
public enum PluginRowDetailResult: Sendable, Equatable {
    case markdown(String)
    case failure(String)
}

/// A palette row source contributed by a Native Plugin (e.g. hosts profile
/// rows). Descriptor-based per ADR-0007: Core surfaces the rows generically
/// and performs a committed row through this protocol, never through a
/// plugin-named code path.
@MainActor
public protocol PluginRowSource: AnyObject {
    /// Stable identity within the owning plugin. Core namespaces this value
    /// with the plugin id for registration, unregistration, and commit
    /// routing.
    var id: String { get }

    /// String-catalog key for the palette section header this source's rows
    /// appear under (user story 27: plugin strings live in the shared
    /// catalog; the host resolves the key against the active language).
    var sectionTitleKey: String { get }

    /// One refresh at palette open (e.g. re-fetch the backing rows).
    /// `rows()` runs on every query pass and must stay cheap, so any real
    /// fetch belongs here.
    func reload()

    /// The rows to surface right now, in display order. Rebuilt on every
    /// palette query pass; must be cheap and synchronous.
    func rows() -> [PluginRowDescriptor]

    /// Whether `rows()` is authoritative, still loading, or failed to build.
    /// Defaults to `.ready` for synchronous sources.
    var loadState: PluginRowLoadState { get }

    /// Runs the action behind a committed row.
    func performRow(id: String) async

    /// Runs the action behind a committed row, passing an Argument-input
    /// string. Defaults to ignoring the argument and calling `performRow(id:)`,
    /// so only sources that opt into Argument input implement it.
    func performRow(id: String, argument: String) async

    /// Builds a row's markdown Detail, or `nil` when the source has none.
    /// Called when a row whose descriptor declared `.pushDetail` is committed.
    func loadDetail(id: String) async -> PluginRowDetailResult?
}

extension PluginRowSource {
    public func reload() {}
    public var loadState: PluginRowLoadState { .ready }
    public func performRow(id: String, argument: String) async {
        await performRow(id: id)
    }
    public func loadDetail(id: String) async -> PluginRowDetailResult? { nil }
}
