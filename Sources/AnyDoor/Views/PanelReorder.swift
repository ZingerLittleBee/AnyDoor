import Foundation

/// Which reorderable group a flat Panel-settings list row belongs to.
///
/// The Panel settings list is rendered as a single flat `List` so that app
/// shortcut children and window-layout children become real, individually
/// draggable rows. A nested `ForEach { … }.onMove(…)` inside a composed parent
/// row never wires into the List's reordering machinery, so the children could
/// not be dragged. Because every row now shares one `onMove`, each row carries
/// the group it is allowed to reorder within.
enum PanelDragGroup: Equatable {
    case topLevel
    case appChild
    case windowChild
    /// Non-draggable adornment rows (the "add app" button, brightness recorders).
    case fixed
}

/// Pure translation of a flat-list `onMove` into a single-group reordering.
enum PanelReorder {
    /// Map a flat `onMove(from:to:)` over heterogeneous rows onto a reordering
    /// confined to the dragged row's own group.
    ///
    /// - Parameters:
    ///   - groups: the drag-group of each flat row, in display order.
    ///   - source: the dragged row indices (SwiftUI passes a single index).
    ///   - destination: SwiftUI's insertion index, in pre-removal index space.
    /// - Returns: the group being reordered plus the `from`/`to` offsets within
    ///   that group (ready for `Array.move(fromOffsets:toOffset:)`), or `nil`
    ///   when the moved row is non-draggable or the source is out of range.
    ///
    /// A drop outside the dragged row's group is clamped to the nearest in-group
    /// slot, so a drag can never escape its group.
    static func localMove(
        groups: [PanelDragGroup],
        from source: IndexSet,
        to destination: Int
    ) -> (group: PanelDragGroup, from: Int, to: Int)? {
        guard let sourceIndex = source.first, groups.indices.contains(sourceIndex) else { return nil }
        let group = groups[sourceIndex]
        guard group != .fixed else { return nil }

        let groupFlatIndices = groups.indices.filter { groups[$0] == group }
        guard let from = groupFlatIndices.firstIndex(of: sourceIndex) else { return nil }
        // Count group rows that sit before the flat insertion point; that is the
        // destination offset within the group in the same pre-removal space that
        // `Array.move(fromOffsets:toOffset:)` expects.
        let to = groupFlatIndices.filter { $0 < destination }.count
        return (group, from, to)
    }
}
