import XCTest
import AppKit
@testable import AnyDoor

@MainActor
final class HyperKeyServiceTests: XCTestCase {
    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "hyperKey.trigger")
        UserDefaults.standard.removeObject(forKey: "hyperKey.quickPress")
        UserDefaults.standard.removeObject(forKey: "hyperKey.includeShift")
        UserDefaults.standard.removeObject(forKey: "hyperKey.ownedSignatures")
    }

    func testFlagsWhenInactive() {
        let s = HyperKeyService()
        XCTAssertEqual(s.hyperModifierFlags, 0)
        XCTAssertEqual(s.virtualKeyCode, -1)
    }

    func testIncludeShiftDefaultTrue() {
        let s = HyperKeyService()
        XCTAssertTrue(s.includeShift)
    }

    func testPersistedSettingsRoundTrip() async {
        UserDefaults.standard.set("capsLock", forKey: "hyperKey.trigger")
        UserDefaults.standard.set("escape", forKey: "hyperKey.quickPress")
        UserDefaults.standard.set(false, forKey: "hyperKey.includeShift")
        let s = HyperKeyService()
        XCTAssertEqual(s.trigger, .capsLock)
        XCTAssertEqual(s.quickPress, .escape)
        XCTAssertFalse(s.includeShift)
    }
}
