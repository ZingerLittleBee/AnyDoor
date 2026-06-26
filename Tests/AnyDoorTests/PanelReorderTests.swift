import Foundation
import Testing
@testable import AnyDoor

/// `PanelReorder.localMove` translates a flat-list `onMove(from:to:)` over
/// heterogeneous Panel-settings rows into a reordering confined to the dragged
/// row's own group. These tests pin the index math that keeps app-shortcut and
/// window-layout children draggable without letting a drag escape its group.
struct PanelReorderTests {

    /// A representative flattened Panel list (general bucket first, then a
    /// themed section with a header):
    ///   0  topLevel(.general)  appShortcuts (parent)
    ///   1  appChild            Codex
    ///   2  appChild            ChatGPT
    ///   3  fixed               add-app button
    ///   4  topLevel(.general)  clipboard
    ///   5  topLevel(.general)  windowLayout (parent)
    ///   6  windowChild         left half
    ///   7  windowChild         right half
    ///   8  groupHeader         "Toggles & Appearance"
    ///   9  topLevel(.togglesAppearance) brightness
    ///  10  fixed               brightness recorders
    ///  11  topLevel(.togglesAppearance) muteAudio
    ///  12  groupHeader         "Power & Session"
    ///  13  topLevel(.powerSession) lockScreen
    private let groups: [PanelDragGroup] = [
        .topLevel(.general),
        .appChild, .appChild,
        .fixed,
        .topLevel(.general),
        .topLevel(.general),
        .windowChild, .windowChild,
        .groupHeader,
        .topLevel(.togglesAppearance),
        .fixed,
        .topLevel(.togglesAppearance),
        .groupHeader,
        .topLevel(.powerSession),
    ]

    @Test func movesAppChildToFrontOfItsGroup() {
        // Drag ChatGPT (flat 2) before Codex (insertion index 1).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 2), to: 1)
        #expect(result?.group == .appChild)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func topLevelDragIsConfinedToItsOwnGroup() {
        // Drag muteAudio (flat 11, the 2nd toggles item) above brightness
        // (insertion index 9). Only the two togglesAppearance rows count.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 11), to: 9)
        #expect(result?.group == .topLevel(.togglesAppearance))
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func generalTopLevelDragSkipsChildrenAndOtherGroups() {
        // Drag windowLayout (flat 5, the 3rd general row) to the very top.
        // General flat indices are [0,4,5]; windowLayout is local index 2.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 5), to: 0)
        #expect(result?.group == .topLevel(.general))
        #expect(result?.from == 2)
        #expect(result?.to == 0)
    }

    @Test func draggingAHeaderReordersAmongHeaders() {
        // Drag the "Power & Session" header (flat 12) above the
        // "Toggles & Appearance" header (insertion index 8). Header flat
        // indices are [8,12]; the dragged one is local index 1.
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 12), to: 8)
        #expect(result?.group == .groupHeader)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func reordersWindowChildren() {
        // Drag the second window child (flat 7) before the first (insertion index 6).
        let result = PanelReorder.localMove(groups: groups, from: IndexSet(integer: 7), to: 6)
        #expect(result?.group == .windowChild)
        #expect(result?.from == 1)
        #expect(result?.to == 0)
    }

    @Test func fixedRowsAreNotReorderable() {
        // The add-app button (flat 3) and brightness recorders (flat 10) never move.
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 3), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 10), to: 0) == nil)
    }

    @Test func emptyOrOutOfRangeSourceReturnsNil() {
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(), to: 0) == nil)
        #expect(PanelReorder.localMove(groups: groups, from: IndexSet(integer: 99), to: 0) == nil)
    }
}
