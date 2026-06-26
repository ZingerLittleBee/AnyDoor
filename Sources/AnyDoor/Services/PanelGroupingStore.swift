import Foundation
import Observation

/// Persists the Panel settings page's themed-group order and collapse state in
/// UserDefaults (no SwiftData involvement). `@Observable` so the settings view
/// re-renders when order/collapse change. `.general` is the implicit,
/// headerless, always-first bucket: it is never stored in the order array and
/// can never be collapsed.
@MainActor
@Observable
final class PanelGroupingStore {
    static let shared = PanelGroupingStore()

    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let order = "panel.groupOrder"
        static let collapsed = "panel.collapsedGroups"
        static let collapsedParents = "panel.collapsedParents"
    }

    private(set) var themedOrder: [BuiltinGroup]
    private(set) var collapsedGroups: Set<BuiltinGroup>
    private(set) var collapsedParents: Set<BuiltinItem>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themedOrder = Self.reconcile(defaults.array(forKey: Keys.order) as? [String] ?? [])
        self.collapsedGroups = Set(
            (defaults.array(forKey: Keys.collapsed) as? [String] ?? [])
                .compactMap(BuiltinGroup.init(rawValue:))
                .filter { $0 != .general }
        )
        self.collapsedParents = Set(
            (defaults.array(forKey: Keys.collapsedParents) as? [String] ?? [])
                .compactMap(BuiltinItem.init(rawValue:))
        )
    }

    /// Drop unknown ids, `.general`, and duplicates; append any themed group
    /// missing from the stored order in default order. Never crashes on
    /// malformed input.
    private static func reconcile(_ stored: [String]) -> [BuiltinGroup] {
        var result: [BuiltinGroup] = []
        var seen = Set<BuiltinGroup>()
        for raw in stored {
            guard let group = BuiltinGroup(rawValue: raw),
                  group != .general,
                  BuiltinGroup.themedDefaultOrder.contains(group),
                  seen.insert(group).inserted else { continue }
            result.append(group)
        }
        for group in BuiltinGroup.themedDefaultOrder where !seen.contains(group) {
            result.append(group)
        }
        return result
    }

    func setThemedOrder(_ groups: [BuiltinGroup]) {
        themedOrder = Self.reconcile(groups.map(\.rawValue))
        defaults.set(themedOrder.map(\.rawValue), forKey: Keys.order)
    }

    func isCollapsed(_ group: BuiltinGroup) -> Bool {
        group != .general && collapsedGroups.contains(group)
    }

    func setCollapsed(_ group: BuiltinGroup, _ collapsed: Bool) {
        guard group != .general else { return }
        if collapsed { collapsedGroups.insert(group) } else { collapsedGroups.remove(group) }
        defaults.set(collapsedGroups.map(\.rawValue), forKey: Keys.collapsed)
    }

    func isParentCollapsed(_ item: BuiltinItem) -> Bool {
        collapsedParents.contains(item)
    }

    func setParentCollapsed(_ item: BuiltinItem, _ collapsed: Bool) {
        if collapsed { collapsedParents.insert(item) } else { collapsedParents.remove(item) }
        defaults.set(collapsedParents.map(\.rawValue), forKey: Keys.collapsedParents)
    }

    /// Sort index used by `PanelStore.rebuild()`: `.general` is 0 (always first),
    /// themed groups follow in user order starting at 1.
    func orderIndex(for group: BuiltinGroup) -> Int {
        guard group != .general else { return 0 }
        return themedOrder.firstIndex(of: group).map { $0 + 1 } ?? Int.max
    }
}
