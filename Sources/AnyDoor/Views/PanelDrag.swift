import CoreGraphics

/// Pure geometry + ordering helpers for the Panel settings drag-to-reorder
/// gesture. Kept free of SwiftUI so the projection and reorder math are
/// unit-testable without a view.
///
/// The settings list renders in a plain `VStack` (not a `List`), so reordering
/// is driven by a custom `DragGesture` instead of `.onMove`. A drag is always
/// scoped to one `PanelDragGroup`: a row can only move among its peers.
enum PanelDrag {
    /// The insertion index a dragged row would land at, given the drag pointer's
    /// Y and the vertical midpoints of its *peers* (every same-group row **except
    /// the dragged one**). Equals the number of peers sitting above the pointer.
    ///
    /// Midpoints need not be sorted; the result is clamped to `0...peerMidYs.count`.
    static func dropIndex(pointerY: CGFloat, peerMidYs: [CGFloat]) -> Int {
        peerMidYs.reduce(into: 0) { count, midY in
            if midY < pointerY { count += 1 }
        }
    }

    /// `items` with `dragged` lifted out and reinserted at `index` counted among
    /// the *remaining* elements (i.e. the value returned by `dropIndex`). The
    /// index is clamped, so an out-of-range drop stays valid.
    ///
    /// `items` is the group's full peer order including `dragged`; the result is
    /// the new order to hand to a `PanelStore` reorder method.
    static func reordered<T: Equatable>(_ items: [T], moving dragged: T, to index: Int) -> [T] {
        var others = items.filter { $0 != dragged }
        let clamped = max(0, min(index, others.count))
        others.insert(dragged, at: clamped)
        return others
    }
}
