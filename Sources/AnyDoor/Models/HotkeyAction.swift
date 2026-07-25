import Foundation
import PluginInterface

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

/// What the CGEvent tap may still dispatch while the keyboard lock is on.
///
/// "Disable Keyboard" means the keyboard produces nothing: no characters, no modifier
/// state changes, no Hyper combos, no Quick Press. The single exception is the keyboard
/// lock toggle itself, so the same shortcut that armed the lock can release it — the
/// panel row and the menu bar item stay available to the mouse either way.
enum KeyboardLockPolicy {
    static func allowsDispatch(_ action: HotkeyAction, locked: Bool) -> Bool {
        guard locked else { return true }
        guard case .toggleBuiltin(let itemKey) = action else { return false }
        return itemKey == BuiltinItem.keyboardLock.rawValue
    }
}
