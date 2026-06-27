import CoreGraphics
import Testing
@testable import AnyDoor

/// `PanelDrag` is the pure geometry + ordering core of the Panel settings
/// drag-to-reorder gesture (the `List` → `VStack` migration replaced `.onMove`
/// with a custom `DragGesture`). These pin the projection and reinsertion math
/// independent of any view.
struct PanelDragTests {

    // MARK: dropIndex

    @Test func dropIndexCountsPeersAbovePointer() {
        let midYs: [CGFloat] = [10, 30, 50]
        #expect(PanelDrag.dropIndex(pointerY: 0, peerMidYs: midYs) == 0)
        #expect(PanelDrag.dropIndex(pointerY: 20, peerMidYs: midYs) == 1)
        #expect(PanelDrag.dropIndex(pointerY: 40, peerMidYs: midYs) == 2)
        #expect(PanelDrag.dropIndex(pointerY: 100, peerMidYs: midYs) == 3)
    }

    @Test func dropIndexIsOrderIndependent() {
        // Midpoints need not be sorted: the result is still "how many sit above".
        #expect(PanelDrag.dropIndex(pointerY: 40, peerMidYs: [50, 10, 30]) == 2)
    }

    @Test func dropIndexWithNoPeersIsZero() {
        #expect(PanelDrag.dropIndex(pointerY: 25, peerMidYs: []) == 0)
    }

    // MARK: reordered

    @Test func reorderToFront() {
        #expect(PanelDrag.reordered(["a", "b", "c", "d"], moving: "b", to: 0) == ["b", "a", "c", "d"])
    }

    @Test func reorderToBack() {
        // "b" lifted out leaves [a, c, d]; inserting at 3 lands it last.
        #expect(PanelDrag.reordered(["a", "b", "c", "d"], moving: "b", to: 3) == ["a", "c", "d", "b"])
    }

    @Test func reorderToMiddle() {
        #expect(PanelDrag.reordered(["a", "b", "c", "d"], moving: "a", to: 2) == ["b", "c", "a", "d"])
    }

    @Test func reorderInPlaceIsStable() {
        // "b" sits at others-index 1 already; dropping there changes nothing.
        #expect(PanelDrag.reordered(["a", "b", "c", "d"], moving: "b", to: 1) == ["a", "b", "c", "d"])
    }

    @Test func reorderClampsOutOfRangeIndex() {
        #expect(PanelDrag.reordered(["a", "b", "c"], moving: "a", to: 99) == ["b", "c", "a"])
        #expect(PanelDrag.reordered(["a", "b", "c"], moving: "c", to: -5) == ["c", "a", "b"])
    }
}
