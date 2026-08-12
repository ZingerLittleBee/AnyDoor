import Foundation
import ClipboardHistory
import Observation

@MainActor
@Observable
final class ClipboardHistorySelectionModel {
    private var orderedIDs: [ClipboardHistoryEntryID] = []
    private(set) var selectedID: ClipboardHistoryEntryID?
    private(set) var previewedID: ClipboardHistoryEntryID?

    func replaceItems(_ ids: [ClipboardHistoryEntryID]) {
        orderedIDs = ids
        if let selectedID, ids.contains(selectedID) {
            return
        }
        selectedID = ids.first
        previewedID = nil
    }

    func select(_ id: ClipboardHistoryEntryID) {
        guard orderedIDs.contains(id) else { return }
        selectedID = id
    }

    func moveUp() {
        move(delta: -1)
    }

    func moveDown() {
        move(delta: 1)
    }

    func togglePreview() {
        guard let selectedID else { return }
        previewedID = (previewedID == selectedID) ? nil : selectedID
    }

    func closePreview() {
        previewedID = nil
    }

    private func move(delta: Int) {
        guard let selectedID,
              let index = orderedIDs.firstIndex(of: selectedID),
              !orderedIDs.isEmpty else { return }
        let next = min(max(index + delta, 0), orderedIDs.count - 1)
        self.selectedID = orderedIDs[next]
    }
}
