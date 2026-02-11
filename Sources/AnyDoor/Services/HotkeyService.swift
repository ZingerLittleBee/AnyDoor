import Cocoa

@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    fileprivate nonisolated(unsafe) var bindingSnapshots: [BindingSnapshot] = []

    struct BindingSnapshot: Sendable {
        let keyCode: Int
        let modifierFlags: Int
        let appBundleID: String
        let appPath: String
    }

    private init() {}

    func updateBindings(_ bindings: [KeyBinding]) {
        bindingSnapshots = bindings.filter(\.isEnabled).map {
            BindingSnapshot(keyCode: $0.keyCode, modifierFlags: $0.modifierFlags,
                            appBundleID: $0.appBundleID, appPath: $0.appPath)
        }
        // Ensure the tap is running and re-enabled after updates
        if eventTap == nil {
            start()
        } else {
            resume()
        }
        print("AnyDoor: Updated \(bindingSnapshots.count) binding(s)")
        for b in bindingSnapshots {
            print("  keyCode=\(b.keyCode) modifiers=\(b.modifierFlags) app=\(b.appBundleID)")
        }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            print("AnyDoor: Failed to create event tap. Accessibility permission granted: \(AXIsProcessTrusted())")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("AnyDoor: Event tap started successfully")
    }

    func suspend() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    func resume() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    nonisolated static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// Modifier mask that covers only Cmd/Ctrl/Opt/Shift, stripping device-dependent bits
private let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue
    | CGEventFlags.maskControl.rawValue
    | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = Int(event.flags.rawValue & modifierMask)

    for binding in service.bindingSnapshots {
        if binding.keyCode == keyCode && binding.modifierFlags == modifiers {
            let bundleID = binding.appBundleID
            let appPath = binding.appPath
            DispatchQueue.main.async {
                AppSwitcher.toggle(bundleID: bundleID, appPath: appPath)
            }
            return nil // consume the event
        }
    }

    return Unmanaged.passUnretained(event)
}
