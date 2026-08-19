import Foundation
import PluginInterface

/// Block all keyboard input by routing key events through the existing CGEvent tap
/// in `HotkeyService` and swallowing every keyboard-originated event.
///
/// Designed for keyboard cleaning: once enabled, key presses produce no characters,
/// no modifier-state changes, no other hotkeys, no Hyper combos and no Quick Press —
/// the keyboard is inert. Release the lock from the menu-bar row, or by pressing
/// the keyboard-lock hotkey if one is bound (that combo is still swallowed so it
/// does not leak to the frontmost app). Quitting AnyDoor also releases the lock,
/// since the state lives only in the running process — there's no way to brick
/// the keyboard.
actor KeyboardLockProvider: ToggleProvider {
    let itemKey: BuiltinItem = .keyboardLock
    var permission: PermissionStatus { .notRequired }

    func readState() async throws -> Bool {
        await HotkeyService.shared.isKeyboardLocked
    }

    func setState(_ locked: Bool) async throws {
        await HotkeyService.shared.setKeyboardLocked(locked)
    }
}
