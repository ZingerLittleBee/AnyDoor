/// Which reorderable group a flat Panel-settings list row belongs to.
///
/// The Panel settings list is a flat `VStack` of rows (app-shortcut children and
/// window-layout children are real, individually draggable rows). Reordering is
/// a custom `DragGesture` on each row's handle (see `PanelDrag`); every row
/// carries the group it is allowed to reorder within, so a drag stays confined
/// to its siblings.
enum PanelDragGroup: Equatable {
    /// A top-level built-in row, tagged with its themed group so a drag is
    /// confined to siblings in the same group (cross-group dragging is rejected
    /// because `.topLevel(.a) != .topLevel(.b)`).
    case topLevel(BuiltinGroup)
    /// A themed section header row; dragging one reorders the themed groups.
    case groupHeader
    case appChild
    case windowChild
    /// Non-draggable adornment rows (the "add app" button, brightness recorders).
    case fixed
}
