import Foundation

/// Storage keys, default value, and the catalog of SF Symbols offered for the
/// menu bar icon. Consumed by `AnyDoorApp` (keys + default) and
/// `GeneralSettingsView` (the picker).
enum MenuBarIcon {
    struct Choice: Equatable, Sendable {
        let name: String
        let titleKey: L10n.Key
    }

    /// UserDefaults key for whether the menu bar item is shown.
    static let visibilityKey = "menuBar.iconVisible"

    /// UserDefaults key for the selected SF Symbol name.
    static let nameKey = "menuBar.iconName"

    /// Default icon — matches the symbol the app originally shipped with.
    static let defaultName = "door.left.hand.open"

    /// Ordered SF Symbol choices offered in the picker.
    static let choices: [Choice] = [
        Choice(name: "door.left.hand.open", titleKey: .menubarIconDoorLeft),
        Choice(name: "sparkles", titleKey: .menubarIconSparkles),
        Choice(name: "wand.and.sparkles", titleKey: .menubarIconWand),
        Choice(name: "bolt.fill", titleKey: .menubarIconBolt),
        Choice(name: "command", titleKey: .menubarIconCommand),
        Choice(name: "switch.2", titleKey: .menubarIconSwitch),
        Choice(name: "square.grid.2x2", titleKey: .menubarIconGrid2x2),
        Choice(name: "circle.grid.3x3.fill", titleKey: .menubarIconGrid3x3),
        Choice(name: "point.3.connected.trianglepath.dotted", titleKey: .menubarIconConnectedPoints),
        Choice(name: "app.connected.to.app.below.fill", titleKey: .menubarIconAppConnected),
        Choice(name: "arrow.trianglehead.2.clockwise", titleKey: .menubarIconCycle),
        Choice(name: "link", titleKey: .menubarIconLink),
        Choice(name: "network", titleKey: .menubarIconNetwork),
        Choice(name: "globe", titleKey: .menubarIconGlobe),
    ]

    /// Ordered SF Symbol names offered in the picker. Kept for storage and tests
    /// that only need the raw symbol names.
    static let options: [String] = choices.map(\.name)

    /// Current visibility preference. Returns `true` when the key is unset so
    /// fresh installs show the icon — mirrors the `@AppStorage` default.
    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: visibilityKey) as? Bool ?? true
    }

    /// Current icon SF Symbol name, falling back to `defaultName` when unset.
    static var currentName: String {
        UserDefaults.standard.string(forKey: nameKey) ?? defaultName
    }

    @MainActor
    static func localizedTitle(for name: String) -> String {
        if let choice = choices.first(where: { $0.name == name }) {
            return L(choice.titleKey)
        }
        return name
    }
}
