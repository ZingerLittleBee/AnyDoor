import Foundation
import Observation
import SwiftData

enum QuicklinkStoreError: Error, Equatable {
    case linkRequired
    case notConfigured
}

@MainActor
@Observable
final class QuicklinkStore {
    static let shared = QuicklinkStore()

    @ObservationIgnored private var modelContext: ModelContext?
    @ObservationIgnored private let refreshHotkeys: @MainActor () -> Void

    private(set) var quicklinks: [Quicklink] = []

    init(
        modelContext: ModelContext? = nil,
        refreshHotkeys: @escaping @MainActor () -> Void = { HotkeyCoordinator.shared.refresh() }
    ) {
        self.modelContext = modelContext
        self.refreshHotkeys = refreshHotkeys
        rebuild()
    }

    func bootstrap(modelContainer: ModelContainer) {
        modelContext = modelContainer.mainContext
        rebuild()
    }

    func rebuild() {
        guard let modelContext else {
            quicklinks = []
            return
        }
        let descriptor = FetchDescriptor<Quicklink>(
            sortBy: [
                SortDescriptor(\.displayOrder),
                SortDescriptor(\.createdAt),
            ]
        )
        quicklinks = (try? modelContext.fetch(descriptor)) ?? []
    }

    func quicklink(id: UUID) -> Quicklink? {
        guard let modelContext else { return nil }
        let descriptor = FetchDescriptor<Quicklink>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }

    @discardableResult
    func add(name: String, link: String, isVisible: Bool = true) throws -> Quicklink {
        guard let modelContext else { throw QuicklinkStoreError.notConfigured }
        let sanitized = try validate(link: link)
        let row = Quicklink(
            name: name,
            link: sanitized,
            isVisible: isVisible,
            displayOrder: nextDisplayOrder()
        )
        modelContext.insert(row)
        try saveRebuildRefresh()
        return row
    }

    func update(id: UUID, name: String, link: String, isVisible: Bool) throws {
        guard let row = quicklink(id: id) else { return }
        row.name = name
        row.link = try validate(link: link)
        row.isVisible = isVisible
        try saveRebuildRefresh()
    }

    func setVisibility(id: UUID, isVisible: Bool) {
        guard let row = quicklink(id: id), row.isVisible != isVisible else { return }
        row.isVisible = isVisible
        try? saveRebuildRefresh()
    }

    func delete(id: UUID) {
        guard let row = quicklink(id: id), let modelContext else { return }
        modelContext.delete(row)
        try? saveRebuildRefresh()
    }

    func reorder(by newOrder: [UUID]) {
        var order: Double = 100
        for id in newOrder {
            guard let row = quicklink(id: id) else { continue }
            row.displayOrder = order
            order += 100
        }
        try? saveRebuildRefresh()
    }

    func paletteEntries() -> [PanelEntry] {
        quicklinks.compactMap { row in
            guard row.isVisible else { return nil }
            guard !QuicklinkDestination.isSearchTemplate(link: row.link) else { return nil }
            return PanelEntry(
                id: PanelEntry.id(for: .quicklink(id: row.id)),
                source: .quicklink(id: row.id),
                displayOrder: row.displayOrder,
                isVisible: row.isVisible,
                hotkey: nil,
                title: row.displayName,
                subtitle: row.link,
                symbol: "link",
                kind: .action,
                toggleState: nil,
                permission: .notRequired
            )
        }
    }

    private func validate(link: String) throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuicklinkStoreError.linkRequired }
        return trimmed
    }

    private func nextDisplayOrder() -> Double {
        (quicklinks.map(\.displayOrder).max() ?? 0) + 100
    }

    private func saveRebuildRefresh() throws {
        try modelContext?.save()
        rebuild()
        refreshHotkeys()
    }
}
