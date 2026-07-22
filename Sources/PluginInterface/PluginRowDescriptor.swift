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
    /// The first seven cases are author-facing — a plugin declares one per row.
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
        /// Push a searchable second-level list of the plugin's rows, built by the
        /// plugin's `list` entry point for the carried list id. The rows inside
        /// follow their own declared semantics (a `pushDetail` row still pushes a
        /// Detail on top of the list, `openURL`/`copy` close and act, and so on).
        case pushList(String)
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
    /// Short status text rendered as a chip at the row's trailing edge
    /// (e.g. "开启" / "关闭" on a toggle-style row). Nil or empty shows none.
    public let badge: String?
    public let commit: CommitSemantics

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        actionLabel: String? = nil,
        isChecked: Bool = false,
        badge: String? = nil,
        commit: CommitSemantics
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.actionLabel = actionLabel
        self.isChecked = isChecked
        self.badge = badge
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

/// A footer action a Detail document offers (e.g. "翻译"). Invoking it calls
/// `loadDetailAction(id:actionID:)` on the owning source; the returned document
/// replaces the rendered Detail.
public struct PluginRowDetailAction: Hashable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

/// The result of building a row's markdown Detail: the markdown to render, or
/// a failure message to show inline. `nil` from `loadDetail` means the source
/// has no Detail for that row at all.
///
/// `more` is an opaque source-defined cursor: non-nil means the Detail has a
/// further chunk (e.g. the next page of comments), which the palette requests
/// by calling `loadDetail(id:cursor:)` with it when the user scrolls to the
/// bottom. The returned chunk's markdown is appended to the rendered document.
/// `actions` are the document's footer actions; they are read from full
/// documents (initial load and action results) and ignored on appended chunks.
public enum PluginRowDetailResult: Sendable, Equatable {
    case markdown(String, more: String?, actions: [PluginRowDetailAction])
    case failure(String)
}

/// The result of building a `pushList` row's second-level list: the rows to
/// surface, or a failure message to show as a single inline error row. A source
/// that has no list for the requested id returns `nil` from `loadList`, which
/// the palette also renders as an inline error (a `pushList` row with no backing
/// `list` handler is a consistent visible failure, not a silent no-op).
public enum PluginRowListResult: Sendable, Equatable {
    case rows([PluginRowDescriptor])
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
    /// Called with a nil cursor when a row whose descriptor declared
    /// `.pushDetail` is committed, and again with the last result's `more`
    /// cursor when the user scrolls to the bottom of a Detail that has one —
    /// the returned chunk is appended to the rendered document.
    func loadDetail(id: String, cursor: String?) async -> PluginRowDetailResult?

    /// Runs a Detail footer action and builds the replacement document, or
    /// `nil` when the source has no such action. Defaults to `nil`, so only
    /// sources whose Detail declares actions implement it.
    func loadDetailAction(id: String, actionID: String) async -> PluginRowDetailResult?

    /// Builds the second-level rows for a committed `.pushList` row's list id,
    /// or `nil` when the source has no list for that id. Defaults to `nil`, so
    /// only sources with a nested list level (a Script Plugin declaring a
    /// `list` entry point) implement it; synchronous sources (hosts profiles)
    /// never push a list and keep the default.
    func loadList(id listID: String, query: String) async -> PluginRowListResult?
}

extension PluginRowSource {
    public func reload() {}
    public var loadState: PluginRowLoadState { .ready }
    public func performRow(id: String, argument: String) async {
        await performRow(id: id)
    }
    public func loadDetail(id: String, cursor: String?) async -> PluginRowDetailResult? { nil }
    public func loadDetailAction(id: String, actionID: String) async -> PluginRowDetailResult? { nil }
    public func loadList(id listID: String, query: String) async -> PluginRowListResult? { nil }
}
