import AppKit
import CoreGraphics
import IOKit
import IOKit.hidsystem

/// Emits keystroke events for Quick Press. Every CGEvent posted here is
/// tagged with `kAnyDoorSynthesizedEventTag` on `eventSourceUserData` so the
/// HotkeyService tap callback can identify and pass through its own emissions.
enum QuickPressEmitter {
    @MainActor
    static func emit(_ action: HyperKeyQuickPress, trigger: HyperKeyTrigger) {
        switch action {
        case .doesNothing: return
        case .escape:
            postTaggedKey(keyCode: 53)
        case .original:
            emitOriginal(for: trigger)
        }
    }

    @MainActor
    private static func emitOriginal(for trigger: HyperKeyTrigger) {
        switch trigger {
        case .none: return
        case .capsLock:
            toggleCapsLockViaHID()
        case .f1:  postTaggedKey(keyCode: 122)
        case .f2:  postTaggedKey(keyCode: 120)
        case .f3:  postTaggedKey(keyCode: 99)
        case .f4:  postTaggedKey(keyCode: 118)
        case .f5:  postTaggedKey(keyCode: 96)
        case .f6:  postTaggedKey(keyCode: 97)
        case .f7:  postTaggedKey(keyCode: 98)
        case .f8:  postTaggedKey(keyCode: 100)
        case .f9:  postTaggedKey(keyCode: 101)
        case .f10: postTaggedKey(keyCode: 109)
        case .f11: postTaggedKey(keyCode: 103)
        case .f12: postTaggedKey(keyCode: 111)
        case .leftControl, .rightControl:
            postTaggedFlagsPulse(flag: .maskControl)
        case .leftShift, .rightShift:
            postTaggedFlagsPulse(flag: .maskShift)
        case .leftOption, .rightOption:
            postTaggedFlagsPulse(flag: .maskAlternate)
        case .leftCommand, .rightCommand:
            postTaggedFlagsPulse(flag: .maskCommand)
        }
    }

    /// Post a key-down + key-up pair tagged with the synthesized-event sentinel.
    private static func postTaggedKey(keyCode: CGKeyCode) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        for isDown in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: isDown) else { continue }
            ev.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
            ev.post(tap: .cghidEventTap)
        }
    }

    /// Post a flagsChanged down + up pulse tagged with the synthesized-event sentinel.
    /// Used for modifier-key triggers (Ctrl, Shift, Option, Command).
    private static func postTaggedFlagsPulse(flag: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        guard let down = CGEvent(source: src) else { return }
        down.type = .flagsChanged
        down.flags = flag
        down.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
        down.post(tap: .cghidEventTap)

        guard let up = CGEvent(source: src) else { return }
        up.type = .flagsChanged
        up.flags = []
        up.setIntegerValueField(.eventSourceUserData, value: kAnyDoorSynthesizedEventTag)
        up.post(tap: .cghidEventTap)
    }

    /// Toggle Caps Lock state at the HID layer. Uses IOKit because CGEvent.post
    /// cannot toggle the system-level Caps Lock LED/state.
    private static func toggleCapsLockViaHID() {
        var ioConnect: io_connect_t = 0
        let masterPort: mach_port_t = kIOMainPortDefault
        let service = IOServiceGetMatchingService(masterPort, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &ioConnect)
        guard kr == KERN_SUCCESS else { return }
        defer { IOServiceClose(ioConnect) }

        var modifierLockState: Bool = false
        IOHIDGetModifierLockState(ioConnect, Int32(kIOHIDCapsLockState), &modifierLockState)
        IOHIDSetModifierLockState(ioConnect, Int32(kIOHIDCapsLockState), !modifierLockState)
    }
}
