import Cocoa

/// Global hotkey listener service.
///
/// Uses a CGEvent tap at the HID level to intercept keyboard events, matches them
/// against registered key bindings, and invokes AppSwitcher to toggle the target app.
/// Requires Accessibility permission.
///
/// - Note: The callback `hotkeyCallback` is a C-style free function that runs off
///   the main thread. Data is safely shared between this @MainActor-isolated class
///   and the C callback via `BindingSnapshot` (a Sendable value type) stored in
///   `nonisolated(unsafe)` properties.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    /// CGEvent tap port; fileprivate so the free callback function in this file can read it
    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    /// Binding snapshots read by the callback on a non-main thread for key matching
    fileprivate nonisolated(unsafe) var bindingSnapshots: [BindingSnapshot] = []

    /// Periodically checks and re-enables the event tap if the system disabled it
    private var watchdogTimer: Timer?

    /// Sendable value type for safely passing binding data across threads to the C callback
    struct BindingSnapshot: Sendable {
        let keyCode: Int
        let modifierFlags: Int
        let appBundleID: String
        let appPath: String
    }

    private init() {}

    /// Update snapshots with the latest bindings and ensure the event tap is enabled
    func updateBindings(_ bindings: [KeyBinding]) {
        bindingSnapshots = bindings.filter(\.isEnabled).map {
            BindingSnapshot(keyCode: $0.keyCode, modifierFlags: $0.modifierFlags,
                            appBundleID: $0.appBundleID, appPath: $0.appPath)
        }
        // Ensure tap is running (may have been suspended during recording or disabled by system)
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

    /// Create a CGEvent tap and register it on the main RunLoop.
    ///
    /// - `.cghidEventTap`: highest priority, intercepts events before all apps
    /// - `.headInsertEventTap`: inserted at the head of the tap chain
    /// - `.defaultTap` (not listenOnly): allows consuming matched events
    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // passUnretained: HotkeyService is a singleton with app-lifetime, no retain needed
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
        startWatchdog()
        print("AnyDoor: Event tap started successfully")
    }

    /// Suspend event listening (called during hotkey recording to avoid triggering existing bindings)
    func suspend() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    /// Resume event listening
    func resume() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// Fully stop event listening and clean up all resources
    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// Watchdog timer: checks every 5 seconds whether the event tap was disabled by the system.
    ///
    /// macOS enforces a ~1 second timeout on event tap callbacks. If the callback takes
    /// too long, the system auto-disables the tap (firing `.tapDisabledByTimeout`).
    /// Although the callback already handles re-enabling, the system may not deliver
    /// further events to a disabled tap, so this external timer acts as a safety net.
    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("AnyDoor: Watchdog re-enabled event tap")
            }
        }
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    nonisolated static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - CGEvent Tap Callback

/// Mask retaining only Cmd/Ctrl/Opt/Shift, stripping device-dependent bits (NumLock, CapsLock, etc.)
/// Ensures recording and detection use the same mask for comparison
private let modifierMask: UInt64 = CGEventFlags.maskCommand.rawValue
    | CGEventFlags.maskControl.rawValue
    | CGEventFlags.maskAlternate.rawValue
    | CGEventFlags.maskShift.rawValue

/// CGEvent tap callback (C-style free function, not @MainActor).
///
/// - Returns nil to consume a matched event (prevents delivery to other apps)
/// - Returns the original event to pass through unmatched events
/// - Handles system-disabled tap by immediately re-enabling
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

    // System disabled tap due to timeout or user input — re-enable immediately
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // Only handle keyDown events, ignore flagsChanged etc.
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    let modifiers = Int(event.flags.rawValue & modifierMask)

    for binding in service.bindingSnapshots {
        if binding.keyCode == keyCode && binding.modifierFlags == modifiers {
            let bundleID = binding.appBundleID
            let appPath = binding.appPath
            // Dispatch to main thread to avoid blocking the callback and triggering system timeout
            DispatchQueue.main.async {
                AppSwitcher.toggle(bundleID: bundleID, appPath: appPath)
            }
            return nil // consume event
        }
    }

    return Unmanaged.passUnretained(event) // pass through
}
