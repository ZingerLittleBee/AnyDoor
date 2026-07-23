import SwiftUI

/// Host-provided callbacks a plugin's panel popover content uses to
/// cooperate with the menu panel's hover machinery. The host builds one per
/// mount; the closures close over its live hover gate and popover window.
public struct PluginPanelPopoverContext {
    /// Forward the content's hover state so the popover stays open while the
    /// pointer is inside it.
    public let onHoverChange: @MainActor (Bool) -> Void
    /// Hide the popover (resetting the hover gate).
    public let dismissPopover: @MainActor () -> Void
    /// Close the whole menu panel (e.g. before presenting a window).
    public let closePanel: @MainActor () -> Void

    public init(
        onHoverChange: @escaping @MainActor (Bool) -> Void,
        dismissPopover: @escaping @MainActor () -> Void,
        closePanel: @escaping @MainActor () -> Void
    ) {
        self.onHoverChange = onHoverChange
        self.dismissPopover = dismissPopover
        self.closePanel = closePanel
    }
}

/// A hover popover a Native Plugin contributes for one of its claimed
/// submenu commands. The host owns mounting and anchoring; the plugin owns
/// the content.
public struct PluginPanelPopover {
    /// Whether the popover needs key focus (e.g. for a search field).
    public let needsKeyFocus: Bool
    /// Builds the SwiftUI content for one mount.
    public let makeContent: @MainActor (PluginPanelPopoverContext) -> AnyView
    /// Optional refresh run once right after the first mount (off the hover
    /// tick). When it finishes, the host remounts and re-anchors so the
    /// popover resizes to the fresh data instead of clipping to stale state.
    public let refresh: (@MainActor () async -> Void)?

    public init(
        needsKeyFocus: Bool,
        makeContent: @escaping @MainActor (PluginPanelPopoverContext) -> AnyView,
        refresh: (@MainActor () async -> Void)? = nil
    ) {
        self.needsKeyFocus = needsKeyFocus
        self.makeContent = makeContent
        self.refresh = refresh
    }
}
