import Foundation
import Observation

@MainActor
@Observable
final class ClipboardHistorySelectionModel {
    private var orderedIDs: [UUID] = []
    private(set) var selectedID: UUID?
    private(set) var previewedID: UUID?

    func replaceItems(_ ids: [UUID]) {
        orderedIDs = ids
        if let selectedID, ids.contains(selectedID) {
            return
        }
        selectedID = ids.first
        previewedID = nil
    }

    func select(_ id: UUID) {
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
