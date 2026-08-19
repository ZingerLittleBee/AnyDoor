import AppKit
import XCTest
@testable import AnyDoor

final class KeyboardLockEventPolicyTests: XCTestCase {
    private let systemDefined = KeyboardLockEventPolicy.systemDefinedType

    func testLockedAuxControlButtonsAreSwallowed() {
        XCTAssertTrue(KeyboardLockEventPolicy.shouldSwallow(
            locked: true,
            type: systemDefined,
            systemDefinedSubtype: KeyboardLockEventPolicy.auxControlButtonsSubtype
        ))
    }

    func testLockedAuxMouseButtonsPassThrough() {
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true,
            type: systemDefined,
            systemDefinedSubtype: KeyboardLockEventPolicy.auxMouseButtonsSubtype
        ))
    }

    func testUnlockedSystemDefinedPassesThrough() {
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: false,
            type: systemDefined,
            systemDefinedSubtype: KeyboardLockEventPolicy.auxControlButtonsSubtype
        ))
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: false,
            type: systemDefined,
            systemDefinedSubtype: KeyboardLockEventPolicy.auxMouseButtonsSubtype
        ))
    }

    func testLockedOrdinaryKeyEventsRemainSwallowed() {
        XCTAssertTrue(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .keyDown, systemDefinedSubtype: nil
        ))
        XCTAssertTrue(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .keyUp, systemDefinedSubtype: nil
        ))
        XCTAssertTrue(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .flagsChanged, systemDefinedSubtype: nil
        ))
    }

    func testLockedUnknownSystemDefinedSubtypePassesThrough() {
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true,
            type: systemDefined,
            systemDefinedSubtype: nil
        ))
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true,
            type: systemDefined,
            systemDefinedSubtype: 0
        ))
    }

    func testLockedNonKeyboardEventTypesPassThrough() {
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .leftMouseDown, systemDefinedSubtype: nil
        ))
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .mouseMoved, systemDefinedSubtype: nil
        ))
        // These types are not in the tap mask. Extra mouse buttons never
        // reach the lock branch, but the policy must still pass them through.
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .otherMouseDown, systemDefinedSubtype: nil
        ))
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: true, type: .otherMouseUp, systemDefinedSubtype: nil
        ))
    }

    func testSystemDefinedTypeMatchesNSEvent() {
        XCTAssertEqual(systemDefined.rawValue, UInt32(NSEvent.EventType.systemDefined.rawValue))
        XCTAssertEqual(systemDefined.rawValue, 14)
        XCTAssertEqual(KeyboardLockEventPolicy.auxControlButtonsSubtype, 8)
        XCTAssertEqual(KeyboardLockEventPolicy.auxMouseButtonsSubtype, 7)
    }
}
