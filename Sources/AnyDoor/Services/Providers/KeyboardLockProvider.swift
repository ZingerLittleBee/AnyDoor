import Foundation
import PluginInterface

/// Block all keyboard input by routing key events through the existing CGEvent tap
/// in `HotkeyService` and dropping anything that isn't a registered AnyDoor hotkey.
///
/// Designed for keyboard cleaning: once enabled, key presses produce no characters,
/// no modifier-state changes, no hotkeys, no Hyper combos and no Quick Press — the
/// keyboard is inert. Releasing the lock is therefore mouse-only: click the menu bar
/// icon and toggle the row off. Quitting AnyDoor also releases the lock, since the
/// state lives only in the running process — there's no way to brick the keyboard.
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
