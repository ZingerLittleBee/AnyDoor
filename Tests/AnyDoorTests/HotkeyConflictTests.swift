import XCTest
@testable import AnyDoor

final class HotkeyConflictTests: XCTestCase {
    func testMatchByKeyCodeAndModifiers() {
        let snapshots: [HotkeySnapshot] = [
            HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                           action: .launchApp(bundleID: "a", path: "/a")),
            HotkeySnapshot(keyCode: 120, modifierFlags: 256,
                           action: .toggleBuiltin(itemKey: "keepAwake")),
        ]

        let hit = snapshots.first { $0.keyCode == 120 && $0.modifierFlags == 256 }
        XCTAssertNotNil(hit)
        if case let .toggleBuiltin(key) = hit?.action {
            XCTAssertEqual(key, "keepAwake")
        } else {
            XCTFail("wrong action type")
        }
    }

    func testConflictDetectionAcrossLaunchAndBuiltin() {
        let a = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                                action: .launchApp(bundleID: "a", path: "/a"))
        let b = HotkeySnapshot(keyCode: 122, modifierFlags: 0,
                                action: .toggleBuiltin(itemKey: "keepAwake"))

        XCTAssertEqual(a.keyCode, b.keyCode)
        XCTAssertEqual(a.modifierFlags, b.modifierFlags)
        XCTAssertNotEqual(a, b)
    }
}
