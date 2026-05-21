import Foundation

/// Block all keyboard input by routing key events through the existing CGEvent tap
/// in `HotkeyService` and dropping anything that isn't a registered AnyDoor hotkey.
///
/// Designed for keyboard cleaning: once enabled, key presses produce no characters
/// and no modifier-state changes. Registered hotkeys still fire so the same shortcut
/// can toggle the lock back off. Quitting AnyDoor also releases the lock, since the
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
