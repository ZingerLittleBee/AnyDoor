import Foundation
import AppKit
import Observation

/// Stores the command palette's preferences: the global hotkey that summons
/// it and the installed apps hidden from its Applications section.
///
/// Both live in `UserDefaults` (no SwiftData migration cost). The hotkey is
/// merged by `HotkeyCoordinator.refresh()` so updates flow into the CGEvent
/// tap automatically; the palette reads the hidden apps each time it opens.
@MainActor
@Observable
final class CommandPaletteService {
    static let shared = CommandPaletteService()

    private static let keyCodeDefaultsKey = "commandPalette.hotkey.keyCode"
    private static let modifiersDefaultsKey = "commandPalette.hotkey.modifierFlags"
    nonisolated static let hiddenAppsDefaultsKey = "commandPalette.hiddenAppBundleIDs"

    private(set) var hotkey: HotkeyDescriptor?
    /// Bundle IDs of scanned apps the palette leaves out, in the order they
    /// were hidden. App shortcuts are never hidden.
    private(set) var hiddenAppBundleIDs: [String]

    private init() {
        self.hotkey = Self.readFromDefaults()
        self.hiddenAppBundleIDs = Self.readHiddenApps()
    }

    func hideApp(bundleID: String) {
        guard !hiddenAppBundleIDs.contains(bundleID) else { return }
        hiddenAppBundleIDs.append(bundleID)
        UserDefaults.standard.set(hiddenAppBundleIDs, forKey: Self.hiddenAppsDefaultsKey)
    }

    func showApp(bundleID: String) {
        hiddenAppBundleIDs.removeAll { $0 == bundleID }
        UserDefaults.standard.set(hiddenAppBundleIDs, forKey: Self.hiddenAppsDefaultsKey)
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

    /// Re-read the preferences from UserDefaults after an external write (config
    /// import) and rebuild the hotkey snapshots so the CGEvent tap picks it up.
    func reloadFromDefaults() {
        hotkey = Self.readFromDefaults()
        hiddenAppBundleIDs = Self.readHiddenApps()
        HotkeyCoordinator.shared.refresh()
    }

    private static func readHiddenApps() -> [String] {
        UserDefaults.standard.stringArray(forKey: hiddenAppsDefaultsKey) ?? []
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
