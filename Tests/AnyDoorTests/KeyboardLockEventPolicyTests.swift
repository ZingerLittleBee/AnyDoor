import AppKit
import PluginInterface
import XCTest
@testable import AnyDoor

final class KeyboardLockEventPolicyTests: XCTestCase {
    private let systemDefined = KeyboardLockEventPolicy.systemDefinedType
    private let command = Int(CGEventFlags.maskCommand.rawValue)
    private let shift = Int(CGEventFlags.maskShift.rawValue)
    private let hyperFlags = Int(
        CGEventFlags.maskControl.rawValue
            | CGEventFlags.maskAlternate.rawValue
            | CGEventFlags.maskCommand.rawValue
    )
    private let escapeKey = 37
    private let otherKey = 0
    private let hyperVirtualKey = 80

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

    // MARK: - Escape hatch

    func testLockedEscapeHotkeyKeyDownDispatchesAndSwallows() {
        let decision = decide(
            type: .keyDown,
            keyCode: escapeKey,
            modifiers: command,
            escape: cmdEscape()
        )
        XCTAssertEqual(
            decision,
            .swallowAndDispatchEscape(lockHyperHeld: false, suppressKeyCode: escapeKey)
        )
    }

    func testLockedSameKeyWrongModifiersDoesNotDispatch() {
        let decision = decide(
            type: .keyDown,
            keyCode: escapeKey,
            modifiers: command | shift,
            escape: cmdEscape()
        )
        XCTAssertEqual(decision, .swallow(lockHyperHeld: false))
    }

    func testLockedDifferentHotkeyComboDoesNotDispatch() {
        let decision = decide(
            type: .keyDown,
            keyCode: otherKey,
            modifiers: command,
            escape: cmdEscape()
        )
        XCTAssertEqual(decision, .swallow(lockHyperHeld: false))
    }

    func testLockedHyperEscapeComboDispatchesAndTriggerKeyUpDoesNot() {
        let escape = KeyboardLockEventPolicy.EscapeBinding(
            keyCode: escapeKey,
            modifierFlags: hyperFlags
        )

        XCTAssertEqual(
            decide(
                type: .keyDown,
                keyCode: hyperVirtualKey,
                hyperVirtualKeyCode: hyperVirtualKey,
                hyperModifierFlags: hyperFlags,
                escape: escape
            ),
            .swallow(lockHyperHeld: true)
        )

        XCTAssertEqual(
            decide(
                type: .keyDown,
                keyCode: escapeKey,
                modifiers: 0,
                lockHyperHeld: true,
                hyperVirtualKeyCode: hyperVirtualKey,
                hyperModifierFlags: hyperFlags,
                escape: escape
            ),
            .swallowAndDispatchEscape(lockHyperHeld: true, suppressKeyCode: escapeKey)
        )

        XCTAssertEqual(
            decide(
                type: .keyUp,
                keyCode: hyperVirtualKey,
                lockHyperHeld: true,
                hyperVirtualKeyCode: hyperVirtualKey,
                hyperModifierFlags: hyperFlags,
                escape: escape
            ),
            .swallow(lockHyperHeld: false)
        )
    }

    func testHyperCompanionWithoutHeldTriggerDoesNotMatchFoldedEscape() {
        let escape = KeyboardLockEventPolicy.EscapeBinding(
            keyCode: escapeKey,
            modifierFlags: hyperFlags
        )
        let decision = decide(
            type: .keyDown,
            keyCode: escapeKey,
            modifiers: 0,
            lockHyperHeld: false,
            hyperVirtualKeyCode: hyperVirtualKey,
            hyperModifierFlags: hyperFlags,
            escape: escape
        )
        XCTAssertEqual(decision, .swallow(lockHyperHeld: false))
    }

    func testEscapeMatchRequestsKeyUpSuppression() {
        guard case .swallowAndDispatchEscape(_, let suppressKeyCode) = decide(
            type: .keyDown,
            keyCode: escapeKey,
            modifiers: command,
            escape: cmdEscape()
        ) else {
            return XCTFail("expected swallowAndDispatchEscape")
        }
        XCTAssertEqual(suppressKeyCode, escapeKey)
    }

    func testLockedEscapeKeyRepeatDoesNotDispatchAgain() {
        let decision = decide(
            type: .keyDown,
            keyCode: escapeKey,
            modifiers: command,
            escape: cmdEscape(),
            suppressedKeyCodes: [escapeKey]
        )
        XCTAssertEqual(decision, .swallow(lockHyperHeld: false))
    }

    func testLockedEscapeKeyUpIsConsumedWithoutDispatch() {
        let decision = decide(
            type: .keyUp,
            keyCode: escapeKey,
            escape: cmdEscape(),
            suppressedKeyCodes: [escapeKey]
        )
        XCTAssertEqual(
            decision,
            .swallowAndConsumeKeyUp(lockHyperHeld: false, keyCode: escapeKey)
        )
    }

    func testNoEscapeBindingSwallowsEverything() {
        XCTAssertEqual(
            decide(type: .keyDown, keyCode: escapeKey, modifiers: command),
            .swallow(lockHyperHeld: false)
        )
        XCTAssertEqual(
            decide(type: .keyUp, keyCode: escapeKey),
            .swallow(lockHyperHeld: false)
        )
        XCTAssertEqual(
            decide(type: .flagsChanged),
            .swallow(lockHyperHeld: false)
        )
        XCTAssertEqual(
            decide(
                type: systemDefined,
                systemDefinedSubtype: KeyboardLockEventPolicy.auxControlButtonsSubtype
            ),
            .swallow(lockHyperHeld: false)
        )
        XCTAssertEqual(
            decide(
                type: systemDefined,
                systemDefinedSubtype: KeyboardLockEventPolicy.auxMouseButtonsSubtype
            ),
            .passThrough
        )
    }

    func testUnlockedDecideNeverSwallowsOrDispatches() {
        XCTAssertEqual(
            decide(
                locked: false,
                type: .keyDown,
                keyCode: escapeKey,
                modifiers: command,
                escape: cmdEscape()
            ),
            .passThrough
        )
        XCTAssertEqual(
            decide(
                locked: false,
                type: .keyUp,
                keyCode: escapeKey,
                escape: cmdEscape(),
                suppressedKeyCodes: [escapeKey]
            ),
            .passThrough
        )
        XCTAssertEqual(
            decide(
                locked: false,
                type: systemDefined,
                systemDefinedSubtype: KeyboardLockEventPolicy.auxControlButtonsSubtype
            ),
            .passThrough
        )
        XCTAssertFalse(KeyboardLockEventPolicy.shouldSwallow(
            locked: false, type: .keyDown, systemDefinedSubtype: nil
        ))
    }

    func testEscapeBindingExtractsOnlyKeyboardLockToggle() {
        let snapshots = [
            HotkeySnapshot(
                keyCode: otherKey,
                modifierFlags: command,
                action: .toggleBuiltin(itemKey: BuiltinItem.keepAwake.rawValue)
            ),
            HotkeySnapshot(
                keyCode: escapeKey,
                modifierFlags: command,
                action: .toggleBuiltin(itemKey: BuiltinItem.keyboardLock.rawValue)
            ),
            HotkeySnapshot(
                keyCode: 8,
                modifierFlags: command,
                action: .showCommandPalette
            ),
        ]
        XCTAssertEqual(
            KeyboardLockEventPolicy.escapeBinding(from: snapshots),
            KeyboardLockEventPolicy.EscapeBinding(keyCode: escapeKey, modifierFlags: command)
        )
        XCTAssertNil(KeyboardLockEventPolicy.escapeBinding(from: Array(snapshots.prefix(1))))
        XCTAssertNil(KeyboardLockEventPolicy.escapeBinding(from: []))
    }

    func testBuiltinKeyboardLockRawValueIsStable() {
        XCTAssertEqual(BuiltinItem.keyboardLock.rawValue, "keyboardLock")
    }

    // MARK: - Helpers

    private func cmdEscape() -> KeyboardLockEventPolicy.EscapeBinding {
        KeyboardLockEventPolicy.EscapeBinding(keyCode: escapeKey, modifierFlags: command)
    }

    private func decide(
        locked: Bool = true,
        type: CGEventType,
        keyCode: Int = -1,
        modifiers: Int = 0,
        systemDefinedSubtype: Int16? = nil,
        lockHyperHeld: Bool = false,
        hyperVirtualKeyCode: Int = -1,
        hyperModifierFlags: Int = 0,
        escape: KeyboardLockEventPolicy.EscapeBinding? = nil,
        suppressedKeyCodes: Set<Int> = []
    ) -> KeyboardLockEventPolicy.Decision {
        KeyboardLockEventPolicy.decide(
            locked: locked,
            type: type,
            keyCode: keyCode,
            modifiers: modifiers,
            systemDefinedSubtype: systemDefinedSubtype,
            lockHyperHeld: lockHyperHeld,
            hyperVirtualKeyCode: hyperVirtualKeyCode,
            hyperModifierFlags: hyperModifierFlags,
            escape: escape,
            suppressedKeyCodes: suppressedKeyCodes
        )
    }
}
