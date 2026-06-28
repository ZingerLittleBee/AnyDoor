/// Which reorderable group a flat Panel-settings list row belongs to.
///
/// The Panel settings list is a flat `VStack` of rows (top-level built-ins plus
/// app-shortcut children and window-layout children, all individually
/// draggable). Reordering is a custom `DragGesture` on each row's handle (see
/// `PanelDrag`); every row carries the group it is allowed to reorder within, so
/// a drag stays confined to its siblings.
enum PanelDragGroup: Equatable {
    /// A top-level row (built-in command). All top-level rows reorder within one
    /// flat list.
    case topLevel
    case appChild
    case windowChild
    /// Non-draggable adornment rows (the "add app" button, brightness recorders).
    case fixed
}
