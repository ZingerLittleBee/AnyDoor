import Cocoa

@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    // Snapshot of bindings used by the callback — simple value types
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
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: selfPtr
        ) else {
            print("AnyDoor: Failed to create event tap. Check Accessibility permissions.")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passRetained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passRetained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passRetained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags
    let modifiers = Int(flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).rawValue)

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

    return Unmanaged.passRetained(event)
}
