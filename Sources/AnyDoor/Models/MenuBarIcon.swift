import Foundation

/// Storage keys, default value, and the catalog of SF Symbols offered for the
/// menu bar icon. Consumed by `AnyDoorApp` (keys + default) and
/// `GeneralSettingsView` (the picker).
enum MenuBarIcon {
    /// UserDefaults key for whether the menu bar item is shown.
    static let visibilityKey = "menuBar.iconVisible"

    /// UserDefaults key for the selected SF Symbol name.
    static let nameKey = "menuBar.iconName"

    /// Default icon — matches the symbol the app originally shipped with.
    static let defaultName = "door.left.hand.open"

    /// Ordered SF Symbol names offered in the picker. Door theme, on-brand
    /// with the "AnyDoor" name.
    static let options: [String] = [
        "door.left.hand.open",
        "door.left.hand.closed",
        "door.right.hand.open",
        "door.sliding.right.hand.open",
        "door.garage.open",
        "door.french.open",
    ]
}
