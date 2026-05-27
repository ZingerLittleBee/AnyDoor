import Foundation

/// Which physical key the user has assigned as the Hyper trigger.
/// Persisted by `HyperKeyService` as the raw String value.
enum HyperKeyTrigger: String, CaseIterable, Sendable, Hashable, Codable {
    case none
    case capsLock
    case leftControl, leftShift, leftOption, leftCommand
    case rightControl, rightShift, rightOption, rightCommand
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// USB HID usage code (page << 32 | usage) for `hidutil property --set`.
    /// `nil` for `.none`.
    var hidUsage: UInt64? {
        let page: UInt64 = 0x07_0000_0000
        switch self {
        case .none:         return nil
        case .capsLock:     return page | 0x39
        case .leftControl:  return page | 0xE0
        case .leftShift:    return page | 0xE1
        case .leftOption:   return page | 0xE2
        case .leftCommand:  return page | 0xE3
        case .rightControl: return page | 0xE4
        case .rightShift:   return page | 0xE5
        case .rightOption:  return page | 0xE6
        case .rightCommand: return page | 0xE7
        case .f1:  return page | 0x3A
        case .f2:  return page | 0x3B
        case .f3:  return page | 0x3C
        case .f4:  return page | 0x3D
        case .f5:  return page | 0x3E
        case .f6:  return page | 0x3F
        case .f7:  return page | 0x40
        case .f8:  return page | 0x41
        case .f9:  return page | 0x42
        case .f10: return page | 0x43
        case .f11: return page | 0x44
        case .f12: return page | 0x45
        }
    }

    /// Static, language-neutral picker label.
    var displayLabel: String {
        switch self {
        case .none:         return "None"
        case .capsLock:     return "Caps Lock (⇪)"
        case .leftControl:  return "Left Control (⌃)"
        case .leftShift:    return "Left Shift (⇧)"
        case .leftOption:   return "Left Option (⌥)"
        case .leftCommand:  return "Left Command (⌘)"
        case .rightControl: return "Right Control (⌃)"
        case .rightShift:   return "Right Shift (⇧)"
        case .rightOption:  return "Right Option (⌥)"
        case .rightCommand: return "Right Command (⌘)"
        case .f1:  return "F1"
        case .f2:  return "F2"
        case .f3:  return "F3"
        case .f4:  return "F4"
        case .f5:  return "F5"
        case .f6:  return "F6"
        case .f7:  return "F7"
        case .f8:  return "F8"
        case .f9:  return "F9"
        case .f10: return "F10"
        case .f11: return "F11"
        case .f12: return "F12"
        }
    }
}

/// Action when the trigger is tapped without a companion key.
enum HyperKeyQuickPress: String, CaseIterable, Sendable, Hashable, Codable {
    case doesNothing
    case escape
    case original
}

/// Virtual destination key the trigger is remapped to. F19 (keyCode 80) is
/// not in `HyperKeyTrigger`'s allowed set and is unused on real keyboards.
enum HyperKeyVirtualKey: Sendable {
    case f19

    var hidUsage: UInt64 {
        switch self {
        case .f19: return 0x07_0000_0068
        }
    }

    var keyCode: Int {
        switch self {
        case .f19: return 80
        }
    }
}

/// "An entry we may own" in UserKeyMapping. Persisted so a crash can be
/// recovered without nuking third-party mappings.
struct MappingSignature: Codable, Sendable, Hashable {
    let src: UInt64
    let dst: UInt64
}

typealias OwnedSignatures = Set<MappingSignature>

enum HyperKeyError: Error, Sendable, Equatable {
    case hidutilFailed(stderr: String)
    case tapNotRunning
    case timeout

    var userFacingMessage: String {
        switch self {
        case .hidutilFailed: return "hidutil 调用失败"
        case .tapNotRunning: return "辅助功能权限未授予"
        case .timeout:       return "操作超时"
        }
    }
}

/// Tag written to `CGEventField.eventSourceUserData` on every CGEvent we
/// synthesize for Quick Press. The HotkeyService tap callback bypasses any
/// event carrying this tag so we never match our own emissions.
let kAnyDoorSynthesizedEventTag: Int64 = 0x416E794400000001
