import CoreGraphics
import XCTest
@testable import AnyDoor

final class HotkeyCoordinatorTests: XCTestCase {

    private let command = Int(CGEventFlags.maskCommand.rawValue)
    private let control = Int(CGEventFlags.maskControl.rawValue)

    private func makeBinding(keyCode: Int = 1, modifierFlags: Int? = nil) -> KeyBinding {
        KeyBinding(
            keyCode: keyCode,
            modifierFlags: modifierFlags ?? command,
            appBundleID: "com.example.app",
            appName: "Example",
            appPath: "/Applications/Example.app",
            isEnabled: true,
            isVisible: true,
            displayOrder: 100
        )
    }

    @MainActor
    func testAppShortcutCompilesToLaunchApp() {
        let snapshots = HotkeyCoordinator.compile(
            bindings: [makeBinding(keyCode: 11, modifierFlags: control)],
            prefs: [],
            paletteHotkey: nil
        )
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].keyCode, 11)
        XCTAssertEqual(snapshots[0].modifierFlags, control)
        guard case .launchApp(let bundleID, let path) = snapshots[0].action else {
            return XCTFail("expected launchApp, got \(snapshots[0].action)")
        }
        XCTAssertEqual(bundleID, "com.example.app")
        XCTAssertEqual(path, "/Applications/Example.app")
    }

    @MainActor
    func testToggleBuiltinCompilesToToggleAction() {
        let pref = BuiltinPreference(
            itemKey: BuiltinItem.keepAwake.rawValue,
            keyCode: 2,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], paletteHotkey: nil)
        XCTAssertEqual(snapshots.count, 1)
        guard case .toggleBuiltin(let key) = snapshots[0].action else {
            return XCTFail("expected toggleBuiltin, got \(snapshots[0].action)")
        }
        XCTAssertEqual(key, BuiltinItem.keepAwake.rawValue)
    }

    @MainActor
    func testActionBuiltinCompilesToRunAction() {
        let pref = BuiltinPreference(
            itemKey: BuiltinItem.lockScreen.rawValue,
            keyCode: 3,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], paletteHotkey: nil)
        XCTAssertEqual(snapshots.count, 1)
        guard case .runBuiltin(let key) = snapshots[0].action else {
            return XCTFail("expected runBuiltin, got \(snapshots[0].action)")
        }
        XCTAssertEqual(key, BuiltinItem.lockScreen.rawValue)
    }

    @MainActor
    func testHiddenHotkeyItemsCompileToBrightnessActions() {
        let up = BuiltinPreference(
            itemKey: BuiltinItem.brightnessUp.rawValue,
            keyCode: 4,
            modifierFlags: command
        )
        let down = BuiltinPreference(
            itemKey: BuiltinItem.brightnessDown.rawValue,
            keyCode: 5,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [up, down], paletteHotkey: nil)
        XCTAssertEqual(snapshots.map(\.action), [.brightnessUp, .brightnessDown])
    }

    @MainActor
    func testSubmenuAndBrightnessControlAreSkipped() {
        let submenu = BuiltinPreference(
            itemKey: BuiltinItem.appShortcuts.rawValue,
            keyCode: 6,
            modifierFlags: command
        )
        let control = BuiltinPreference(
            itemKey: BuiltinItem.brightness.rawValue,
            keyCode: 7,
            modifierFlags: command
        )
        let snapshots = HotkeyCoordinator.compile(
            bindings: [],
            prefs: [submenu, control],
            paletteHotkey: nil
        )
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testPrefWithoutHotkeyIsSkipped() {
        let pref = BuiltinPreference(itemKey: BuiltinItem.keepAwake.rawValue)
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], paletteHotkey: nil)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testOrphanPrefKeyIsSkipped() {
        let pref = BuiltinPreference(itemKey: "noSuchBuiltin", keyCode: 8, modifierFlags: command)
        let snapshots = HotkeyCoordinator.compile(bindings: [], prefs: [pref], paletteHotkey: nil)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testPaletteHotkeyIsAppended() {
        let descriptor = HotkeyDescriptor(keyCode: 49, modifierFlags: command)
        let snapshots = HotkeyCoordinator.compile(
            bindings: [makeBinding()],
            prefs: [],
            paletteHotkey: descriptor
        )
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[1].keyCode, 49)
        XCTAssertEqual(snapshots[1].action, .showCommandPalette)
    }
}
