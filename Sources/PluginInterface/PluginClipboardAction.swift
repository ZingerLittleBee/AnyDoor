import Foundation

/// Neutral snapshot of a clipboard-history entry's payload, built by the host
/// and handed to plugins. Plugins decide from the payload shape alone whether
/// one of their actions applies — the host never encodes a plugin's policy,
/// and the plugin never sees the host's history model (ADR-0007). Cases grow
/// when a plugin needs another payload shape.
public enum PluginClipboardPayload: Hashable, Sendable {
    /// A stored-bitmap entry (screenshot or copied image). `fileURL` points at
    /// the history's stored bitmap and is nil when the stored file name is
    /// missing; loading it is deferred to `performClipboardAction`.
    case bitmap(fileURL: URL?, displayName: String)
    /// A file-list entry's original paths, in stored order. Existence is
    /// unchecked — the exposure decision must stay disk-free.
    case files([URL])
}

/// A context-menu action a Native Plugin contributes for a clipboard-history
/// entry. Descriptor-based per ADR-0007: the host renders the menu item
/// generically and routes a commit back by `id`, so its control flow never
/// names the plugin behind the action.
public struct PluginClipboardAction: Hashable, Sendable {
    /// Stable identity within the owning plugin; commit routes back through
    /// `performClipboardAction(id:payload:context:)` with this value.
    public let id: String
    /// String-catalog key for the menu title, resolved by the host against
    /// the active language at menu-build time.
    public let titleKey: String
    /// SF Symbol name for the menu item.
    public let symbol: String

    public init(id: String, titleKey: String, symbol: String) {
        self.id = id
        self.titleKey = titleKey
        self.symbol = symbol
    }
}

/// Host-provided callbacks a committed clipboard action uses to cooperate
/// with the clipboard-history window. The host builds one per commit.
public struct PluginClipboardActionContext {
    /// Dismiss the history window without restoring focus, then run the
    /// completion. Presentation that follows the action belongs inside the
    /// completion so the window's slide-out never fights the plugin window's
    /// activation. An action that only reports a failure (e.g. via a toast)
    /// should skip this and leave the window open.
    public let dismissHistoryWindow: @MainActor (_ then: @escaping @MainActor @Sendable () -> Void) -> Void

    public init(
        dismissHistoryWindow: @escaping @MainActor (_ then: @escaping @MainActor @Sendable () -> Void) -> Void
    ) {
        self.dismissHistoryWindow = dismissHistoryWindow
    }
}
