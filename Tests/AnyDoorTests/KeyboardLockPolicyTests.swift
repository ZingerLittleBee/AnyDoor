import XCTest
import PluginInterface
@testable import AnyDoor

final class KeyboardLockPolicyTests: XCTestCase {

    func testUnlockedAllowsEveryAction() {
        let actions: [HotkeyAction] = [
            .launchApp(bundleID: "com.example.app", path: "/Applications/Example.app"),
            .toggleBuiltin(itemKey: BuiltinItem.keepAwake.rawValue),
            .runBuiltin(itemKey: BuiltinItem.screenshot.rawValue),
            .brightnessUp,
            .brightnessDown,
            .showCommandPalette,
            .openQuicklink(id: UUID())
        ]
        for action in actions {
            XCTAssertTrue(KeyboardLockPolicy.allowsDispatch(action, locked: false))
        }
    }

    func testLockedAllowsOnlyTheKeyboardLockToggle() {
        XCTAssertTrue(
            KeyboardLockPolicy.allowsDispatch(
                .toggleBuiltin(itemKey: BuiltinItem.keyboardLock.rawValue),
                locked: true
            )
        )
    }

    func testLockedBlocksEveryOtherAction() {
        let actions: [HotkeyAction] = [
            .launchApp(bundleID: "com.example.app", path: "/Applications/Example.app"),
            .toggleBuiltin(itemKey: BuiltinItem.keepAwake.rawValue),
            .runBuiltin(itemKey: BuiltinItem.keyboardLock.rawValue),
            .brightnessUp,
            .brightnessDown,
            .showCommandPalette,
            .openQuicklink(id: UUID())
        ]
        for action in actions {
            XCTAssertFalse(
                KeyboardLockPolicy.allowsDispatch(action, locked: true),
                "\(action) must not fire while the keyboard is locked"
            )
        }
    }
}
