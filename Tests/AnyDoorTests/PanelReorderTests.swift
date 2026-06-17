import Foundation
import Testing
@testable import AnyDoor

/// `PanelReorder.localMove` translates a flat-list `onMove(from:to:)` over
/// heterogeneous Panel-settings rows into a reordering confined to the dragged
/// row's own group. These tests pin the index math that keeps app-shortcut and
/// window-layout children draggable without letting a drag escape its group.
struct PanelReorderTests {

    /// A representative flattened Panel list:
    ///   0 topLevel   keepAwake
    ///   1 topLevel   appShortcuts (parent)
    ///   2 appChild   Codex
    ///   3 appChild   ChatGPT
    ///   4 appChild   Warp
    ///   5 appChild   Chrome
    ///   6 fixed      add-app button
    ///   7 topLevel   brightness
    ///   8 fixed      brightness recorders
    ///   9 topLevel   windowLayout (parent)
    ///  10 windowChild left half
    ///  11 windowChild right half
    ///  12 topLevel   clipboard
    private let groups: [PanelDragGroup] = [
        .topLevel, .topLevel,
        .appChild, .appChild, .appChild, .appChild,
        .fixed,
        .topLevel,
        .fixed,
        .topLevel,
        .windowChild, .windowChild,
        .topLevel,
    ]

    @Test func movesAppChildToFrontOfItsGroup() {
        // Drag Warp (flat 4) to before Codex (insertion index 2).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 4), to: 2)
        #expect(result?.group == .appChild)
        #expect(result?.from == 2)
        #expect(result?.to == 0)
    }

    @Test func movesAppChildTowardEndOfItsGroup() {
        // Drag Codex (flat 0 within group) to after Warp (insertion index 5).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 2), to: 5)
        #expect(result?.group == .appChild)
        #expect(result?.from == 0)
        #expect(result?.to == 3)
    }

    @Test func dropOutsideTheGroupClampsToTheGroupEnd() {
        // Drag Warp (flat 4) far down into the top-level area (insertion index 12).
        // The move must stay within the app-child group, clamped to its end.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 4), to: 12)
        #expect(result?.group == .appChild)
        #expect(result?.from == 2)
        #expect(result?.to == 4)
    }

    @Test func reordersTopLevelSkippingInterspersedChildren() {
        // Drag windowLayout (flat 9) to the very top (insertion index 0).
        // Top-level flat indices are [0,1,7,9,12]; windowLayout is local index 3.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 9), to: 0)
        #expect(result?.group == .topLevel)
        #expect(result?.from == 3)
        #expect(result?.to == 0)
    }

    @Test func reordersWindowChildren() {
        // Drag the second window child (flat 11) before the first (insertion index 10).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 11), to: 10)
        #expect(result?.group == .windowChild)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func fixedRowsAreNotReorderable() {
        // The add-app button (flat 6) and brightness recorders (flat 8) never move.
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 6), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 8), to: 0) == nil)
    }

    @Test func emptyOrOutOfRangeSourceReturnsNil() {
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 99), to: 0) == nil)
    }
}
