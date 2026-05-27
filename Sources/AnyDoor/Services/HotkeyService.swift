import Cocoa

/// Global hotkey listener service.
///
/// Owns the CGEvent tap at the HID level. On match, dispatches the associated `HotkeyAction`
/// to the main thread for execution by `PanelStore.shared`.
///
/// - Note: The C callback `hotkeyCallback` runs off the main thread. Snapshots are shared
///   via `nonisolated(unsafe)` storage; HotkeySnapshot is Sendable.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()

    fileprivate nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?

    /// Snapshots read by the callback on a non-main thread for matching.
    fileprivate nonisolated(unsafe) var snapshots: [HotkeySnapshot] = []

    private var watchdogTimer: Timer?
    private var isSuspended = false

    /// Dispatcher injected at bootstrap. The callback packs the matched action and the
    /// dispatcher decides what to do with it.
    fileprivate nonisolated(unsafe) var dispatcher: (@MainActor @Sendable (HotkeyAction) -> Void)?

    /// When true, the CGEvent callback drops every key/flag event that doesn't match a
    /// registered hotkey. Used by the "keyboard lock" feature so the user can wipe the
    /// keyboard without producing input. Hotkeys still fire so the same shortcut can
    /// toggle the lock back off.
    fileprivate nonisolated(unsafe) var keyboardLocked: Bool = false

    // MARK: - Hyper Key support

    fileprivate nonisolated(unsafe) var hyperVirtualKeyCode: Int = -1
    fileprivate nonisolated(unsafe) var hyperModifierFlags: Int = 0
    fileprivate nonisolated(unsafe) var hyperQuickPress: HyperKeyQuickPress = .doesNothing

    fileprivate nonisolated(unsafe) var hyperHeld: Bool = false
    fileprivate nonisolated(unsafe) var hyperDownAt: CFTimeInterval = 0
    fileprivate nonisolated(unsafe) var hyperConsumedByOther: Bool = false
    fileprivate nonisolated(unsafe) var suppressedKeyCodes: Set<Int> = []

    /// Closure invoked when a Quick Press should be performed. Wired by AppDelegate.
    nonisolated(unsafe) var quickPressDispatcher: (@MainActor @Sendable (HyperKeyQuickPress) -> Void)?

    private var consecutiveRestartFailures: Int = 0

    enum TapFailureReason: Sendable, Equatable {
        case accessibilityRevoked
        case tapCreateFailed
    }

    enum TapHealth: Sendable, Equatable {
        case healthy
        case suspendedByRecorder
        case transientlyDown
        case failed(reason: TapFailureReason)
    }

    var tapHealth: TapHealth {
        if isSuspended { return .suspendedByRecorder }
        if !HotkeyService.hasAccessibilityPermission { return .failed(reason: .accessibilityRevoked) }
        if eventTap == nil {
            return consecutiveRestartFailures >= 2 ? .failed(reason: .tapCreateFailed) : .transientlyDown
        }
        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            return consecutiveRestartFailures >= 2 ? .failed(reason: .tapCreateFailed) : .transientlyDown
        }
        return .healthy
    }

    func updateHyperConfig(virtualKey: Int, flags: Int, quickPress: HyperKeyQuickPress) {
        hyperVirtualKeyCode = virtualKey
        hyperModifierFlags = flags
        hyperQuickPress = quickPress
    }

    func setQuickPressDispatcher(_ d: @escaping @MainActor @Sendable (HyperKeyQuickPress) -> Void) {
        quickPressDispatcher = d
    }

    private init() {}

    func setDispatcher(_ dispatcher: @escaping @MainActor @Sendable (HotkeyAction) -> Void) {
        self.dispatcher = dispatcher
    }

    func setKeyboardLocked(_ locked: Bool) {
        keyboardLocked = locked
    }

    var isKeyboardLocked: Bool { keyboardLocked }

    func updateSnapshots(_ newSnapshots: [HotkeySnapshot]) {
        snapshots = newSnapshots
        if !isSuspended {
            if eventTap == nil {
                start()
            } else {
                resume()
            }
        }
        print("AnyDoor: Updated \(snapshots.count) hotkey snapshot(s)")
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
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
            print("AnyDoor: Failed to create event tap. AX granted: \(AXIsProcessTrusted())")
            consecutiveRestartFailures += 1
            return
        }

        eventTap = tap
        consecutiveRestartFailures = 0
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startWatchdog()
        print("AnyDoor: Event tap started")
    }

    func suspend() {
        isSuspended = true
        hyperHeld = false
        hyperConsumedByOther = false
        suppressedKeyCodes.removeAll()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    func resume() {
        isSuspended = false
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    func stop() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func restart() {
        print("AnyDoor: Restarting event tap")
        stop()
        start()
    }

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard let tap = self.eventTap else { return }
            let suspended = MainActor.assumeIsolated { self.isSuspended }
            if !suspended && !CGEvent.tapIsEnabled(tap: tap) {
                print("AnyDoor: Watchdog detected disabled tap, restarting")
                MainActor.assumeIsolated { self.restart() }
            }
        }
    }

    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    nonisolated static func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - CGEvent Callback

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
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        print("AnyDoor: Tap disabled by \(reason), inline re-enable")
        if let tap = service.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Int(event.flags.rawValue & modifierMask)

        for snapshot in service.snapshots {
            if snapshot.keyCode == keyCode && snapshot.modifierFlags == modifiers {
                let action = snapshot.action
                let dispatcher = service.dispatcher
                DispatchQueue.main.async {
                    dispatcher?(action)
                }
                return nil // consume
            }
        }
    }

    // Keyboard-lock mode: swallow any keyDown / flagsChanged that didn't match a hotkey.
    // Registered hotkeys above still fire so the user can toggle the lock back off.
    if service.keyboardLocked && (type == .keyDown || type == .flagsChanged) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
