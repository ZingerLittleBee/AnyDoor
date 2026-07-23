import Foundation
import Observation
import PluginInterface

/// Persists the Panel settings page's parent-row collapse state in UserDefaults
/// (no SwiftData involvement). `@Observable` so the settings view re-renders when
/// it changes.
///
/// Only rows that own children (`appShortcuts`, `windowLayout`, `brightness`)
/// are collapsible; the page is otherwise a flat, ungrouped list ordered by
/// `displayOrder`.
@MainActor
@Observable
final class PanelGroupingStore {
    static let shared = PanelGroupingStore()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let collapsedParents = "panel.collapsedParents"
    }

    private(set) var collapsedParents: Set<BuiltinItem>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.collapsedParents = Set(
            (defaults.array(forKey: Keys.collapsedParents) as? [String] ?? [])
                .compactMap(BuiltinItem.init(rawValue:))
        )
    }

    func isParentCollapsed(_ item: BuiltinItem) -> Bool {
        collapsedParents.contains(item)
    }

    func setParentCollapsed(_ item: BuiltinItem, _ collapsed: Bool) {
        if collapsed { collapsedParents.insert(item) } else { collapsedParents.remove(item) }
        defaults.set(collapsedParents.map(\.rawValue), forKey: Keys.collapsedParents)
    }
}
