import Foundation

/// A command-palette row contributed by a Native Plugin (ADR-0007).
///
/// Plugins never build `PanelEntry` — that type and its `Source` payloads are
/// Core-internal. A plugin declares its rows as pure descriptors instead;
/// Core maps each descriptor onto the generic `Source.pluginRow` case and
/// routes a committed row back to its owning `PluginRowSource` by `id`, so
/// Core control flow never names the plugin behind a row.
public struct PluginRowDescriptor: Hashable, Sendable {
    /// What committing the row means to the palette. The commit-intent
    /// classifier maps a plugin row by this declared value alone.
    public enum CommitSemantics: Hashable, Sendable {
        /// The palette dismisses first, then the row's action runs
        /// (e.g. toggling a hosts profile).
        case closeThenAct
        /// The palette stays open while the row's action runs.
        case stayOpen
    }

    /// Stable identity within the owning row source; commit routes back
    /// through `PluginRowSource.performRow(id:)` with this value.
    public let id: String
    public let title: String
    public let subtitle: String?
    /// SF Symbol name.
    public let symbol: String
    public let commit: CommitSemantics

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbol: String,
        commit: CommitSemantics
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.commit = commit
    }
}

/// A palette row source contributed by a Native Plugin (e.g. hosts profile
/// rows). Descriptor-based per ADR-0007: Core surfaces the rows generically
/// and performs a committed row through this protocol, never through a
/// plugin-named code path.
@MainActor
public protocol PluginRowSource: AnyObject {
    /// The rows to surface right now, rebuilt on every palette query pass.
    func rows() async -> [PluginRowDescriptor]

    /// Runs the action behind a committed row.
    func performRow(id: String) async
}
