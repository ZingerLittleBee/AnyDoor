import Foundation
import Observation
import SwiftData

enum QuicklinkStoreError: Error, Equatable {
    case linkRequired
    case keywordAlreadyUsed
    case notConfigured
}

struct QuicklinkTemplateCandidate: Equatable {
    let id: UUID
    let title: String
    let keyword: String?
    let link: String
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
    func add(name: String, link: String, keyword: String? = nil, isVisible: Bool = true) throws -> Quicklink {
        guard let modelContext else { throw QuicklinkStoreError.notConfigured }
        let sanitizedLink = try validate(link: link)
        let sanitizedKeyword = try validate(keyword: keyword, excluding: nil)
        let row = Quicklink(
            name: name,
            keyword: sanitizedKeyword,
            link: sanitizedLink,
            isVisible: isVisible,
            displayOrder: nextDisplayOrder()
        )
        modelContext.insert(row)
        try saveRebuildRefresh()
        return row
    }

    func update(id: UUID, name: String, link: String, keyword: String? = nil, isVisible: Bool) throws {
        guard let row = quicklink(id: id) else { return }
        let sanitizedLink = try validate(link: link)
        let sanitizedKeyword = try validate(keyword: keyword, excluding: id)
        row.name = name
        row.keyword = sanitizedKeyword
        row.link = sanitizedLink
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
        quicklinks.compactMap { row -> PanelEntry? in
            guard row.isVisible else { return nil }
            let isTemplate = QuicklinkDestination.isSearchTemplate(link: row.link)
            let source: PanelEntry.Source = isTemplate
                ? .quicklinkTemplate(id: row.id)
                : .quicklink(id: row.id)
            return PanelEntry(
                id: PanelEntry.id(for: source),
                source: source,
                displayOrder: row.displayOrder,
                isVisible: row.isVisible,
                hotkey: nil,
                title: row.displayName,
                subtitle: row.link,
                searchAliases: paletteSearchAliases(for: row),
                symbol: "link",
                kind: .action,
                toggleState: nil,
                permission: .notRequired
            )
        }
    }

    func templateCandidates() -> [QuicklinkTemplateCandidate] {
        quicklinks.compactMap { row -> QuicklinkTemplateCandidate? in
            guard row.isVisible,
                  QuicklinkDestination.isSearchTemplate(link: row.link) else { return nil }
            return QuicklinkTemplateCandidate(
                id: row.id,
                title: row.displayName,
                keyword: normalizedKeyword(for: row),
                link: row.link
            )
        }
    }

    private func validate(link: String) throws -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuicklinkStoreError.linkRequired }
        return trimmed
    }

    private func validate(keyword: String?, excluding excludedID: UUID?) throws -> String? {
        let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let duplicate = quicklinks.contains { row in
            if let excludedID, row.id == excludedID { return false }
            guard let existing = row.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !existing.isEmpty else { return false }
            return existing.compare(trimmed, options: [.caseInsensitive]) == .orderedSame
        }
        guard !duplicate else { throw QuicklinkStoreError.keywordAlreadyUsed }
        return trimmed
    }

    private func paletteSearchAliases(for row: Quicklink) -> [String] {
        normalizedKeyword(for: row).map { [$0] } ?? []
    }

    private func normalizedKeyword(for row: Quicklink) -> String? {
        guard let keyword = row.keyword?.trimmingCharacters(in: .whitespacesAndNewlines),
              !keyword.isEmpty else { return nil }
        return keyword
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
