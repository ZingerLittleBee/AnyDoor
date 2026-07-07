import Foundation
import AppKit
import Observation

/// Stores the global hotkey that summons the command palette.
///
/// The hotkey lives in `UserDefaults` (no SwiftData migration cost) and is
/// merged by `HotkeyCoordinator.refresh()` so updates flow into the
/// CGEvent tap automatically.
@MainActor
@Observable
final class CommandPaletteService {
    static let shared = CommandPaletteService()

    private static let keyCodeDefaultsKey = "commandPalette.hotkey.keyCode"
    private static let modifiersDefaultsKey = "commandPalette.hotkey.modifierFlags"

    private(set) var hotkey: HotkeyDescriptor?

    private init() {
        self.hotkey = Self.readFromDefaults()
    }

    /// Persist a new hotkey (or clear it) and trigger a snapshot rebuild so the
    /// CGEvent tap picks up the change.
    func setHotkey(_ descriptor: HotkeyDescriptor?) {
        hotkey = descriptor
        let defaults = UserDefaults.standard
        if let descriptor {
            defaults.set(descriptor.keyCode, forKey: Self.keyCodeDefaultsKey)
            defaults.set(descriptor.modifierFlags, forKey: Self.modifiersDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.keyCodeDefaultsKey)
            defaults.removeObject(forKey: Self.modifiersDefaultsKey)
        }
        HotkeyCoordinator.shared.refresh()
    }

    /// Re-read the hotkey from UserDefaults after an external write (config import)
    /// and rebuild the hotkey snapshots so the CGEvent tap picks it up.
    func reloadFromDefaults() {
        hotkey = Self.readFromDefaults()
        HotkeyCoordinator.shared.refresh()
    }

    private static func readFromDefaults() -> HotkeyDescriptor? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeDefaultsKey) != nil,
              defaults.object(forKey: modifiersDefaultsKey) != nil
        else { return nil }
        let keyCode = defaults.integer(forKey: keyCodeDefaultsKey)
        let mods = defaults.integer(forKey: modifiersDefaultsKey)
        return HotkeyDescriptor(keyCode: keyCode, modifierFlags: mods)
    }
}
