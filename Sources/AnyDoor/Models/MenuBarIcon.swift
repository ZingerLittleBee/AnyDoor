import Foundation

/// Storage keys, default value, and the catalog of SF Symbols offered for the
/// menu bar icon. Consumed by `AnyDoorApp` (keys + default) and
/// `GeneralSettingsView` (the picker).
enum MenuBarIcon {
    struct Choice: Equatable, Sendable {
        let name: String
        let title: String
    }

    /// UserDefaults key for whether the menu bar item is shown.
    static let visibilityKey = "menuBar.iconVisible"

    /// UserDefaults key for the selected SF Symbol name.
    static let nameKey = "menuBar.iconName"

    /// Default icon — matches the symbol the app originally shipped with.
    static let defaultName = "door.left.hand.open"

    /// Ordered SF Symbol choices offered in the picker.
    static let choices: [Choice] = [
        Choice(name: "door.left.hand.open", title: "左开门"),
        Choice(name: "sparkles", title: "闪光"),
        Choice(name: "wand.and.sparkles", title: "魔杖"),
        Choice(name: "bolt.fill", title: "闪电"),
        Choice(name: "command", title: "Command"),
        Choice(name: "switch.2", title: "切换"),
        Choice(name: "square.grid.2x2", title: "网格"),
        Choice(name: "circle.grid.3x3.fill", title: "九宫格"),
        Choice(name: "point.3.connected.trianglepath.dotted", title: "连接点"),
        Choice(name: "app.connected.to.app.below.fill", title: "应用连接"),
        Choice(name: "arrow.trianglehead.2.clockwise", title: "循环"),
        Choice(name: "link", title: "链接"),
        Choice(name: "network", title: "网络"),
        Choice(name: "globe", title: "地球"),
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

    static func title(for name: String) -> String {
        choices.first { $0.name == name }?.title ?? name
    }
}
