import Foundation

/// The action a matched hotkey should perform.
///
/// `launchApp` keeps the existing AppSwitcher behavior; `toggleBuiltin` and `runBuiltin`
/// route through PanelStore to a registered provider.
enum HotkeyAction: Sendable, Hashable {
    case launchApp(bundleID: String, path: String)
    case toggleBuiltin(itemKey: String)
    case runBuiltin(itemKey: String)
    case brightnessUp
    case brightnessDown
    case showCommandPalette
    case openQuicklink(id: UUID)
}

/// Sendable snapshot passed across the CGEvent tap boundary.
///
/// HotkeyService stores `[HotkeySnapshot]` in `nonisolated(unsafe)` storage and the C
/// callback iterates it to find a match. On hit, the action is dispatched to the main thread.
struct HotkeySnapshot: Sendable, Hashable {
    let keyCode: Int
    let modifierFlags: Int
    let action: HotkeyAction
}
