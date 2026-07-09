import Cocoa

/// Global hotkey listener service.
///
/// Owns the CGEvent tap at the HID level. On match, dispatches the associated `HotkeyAction`
/// to the main thread through the injected dispatcher.
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

    /// When non-nil, the tap stops dispatching bound hotkeys and instead
    /// reports trigger held state to the observer. Companion keyDowns are
    /// allowed to propagate so a HotkeyRecorder NSEvent monitor can capture
    /// them with their natural modifier flags — Caps-Lock-sourced F19 doesn't
    /// always survive a suspended tap, so routing through the tap is the only
    /// reliable detection path.
    fileprivate nonisolated(unsafe) var recordingObserver: (@Sendable (Bool) -> Void)?

    /// Closure invoked when a Quick Press should be performed. Wired by AppDelegate.
    nonisolated(unsafe) var quickPressDispatcher: (@MainActor @Sendable (HyperKeyQuickPress) -> Void)?

    /// Publicly readable current Hyper-held state. The HotkeyRecorder uses
    /// this at commit time so a race between the async observer dispatch and
    /// a companion keyDown can't drop the ✦ folding.
    var isHyperHeld: Bool { hyperHeld }

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

    /// Enter recording mode. The tap stays active so the Hyper trigger (which
    /// some sources, notably Caps-Lock-remapped F19, can't be observed any
    /// other way) is still seen. While set, the tap will: (a) keep tracking
    /// hyperHeld and notify the observer, (b) skip dispatching bound
    /// HotkeySnapshots, and (c) skip Quick Press emission.
    func beginRecording(observer: @escaping @Sendable (Bool) -> Void) {
        recordingObserver = observer
        // Report current state so the recorder reflects a still-held trigger
        // (e.g. user opens settings while Hyper is mid-press — unlikely but cheap).
        if hyperHeld {
            DispatchQueue.main.async { observer(true) }
        }
    }

    func endRecording() {
        recordingObserver = nil
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
            // Run synchronously on the main thread via MainThreadIsolation rather
            // than MainActor.assumeIsolated. assumeIsolated performs a
            // swift_task_isCurrentExecutor identity check that can fault on the
            // main thread after certain system async operations (observed after a
            // ScreenCaptureKit capture leaves the thread's executor tracking
            // dangling). The helper skips that check, so it is safe here.
            MainThreadIsolation.run {
                guard let self, let tap = self.eventTap else { return }
                if !self.isSuspended && !CGEvent.tapIsEnabled(tap: tap) {
                    print("AnyDoor: Watchdog detected disabled tap, restarting")
                    self.restart()
                }
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

    // BYPASS: events we synthesized for Quick Press carry this sentinel and
    // must never be matched against our own snapshots.
    if event.getIntegerValueField(.eventSourceUserData) == kAnyDoorSynthesizedEventTag {
        return Unmanaged.passUnretained(event)
    }

    let virtKey = service.hyperVirtualKeyCode
    let recording = service.recordingObserver

    // 1. Hyper trigger keyDown — set held, swallow.
    if virtKey >= 0 && type == .keyDown
       && Int(event.getIntegerValueField(.keyboardEventKeycode)) == virtKey {
        if !service.hyperHeld {
            service.hyperHeld = true
            service.hyperDownAt = CACurrentMediaTime()
            service.hyperConsumedByOther = false
        }
        if let observer = recording {
            DispatchQueue.main.async { observer(true) }
        }
        return nil
    }

    // 2. Hyper trigger keyUp — possibly fire Quick Press (suppressed in
    //    recording mode so a stray Quick Press doesn't escape into the field).
    if virtKey >= 0 && type == .keyUp
       && Int(event.getIntegerValueField(.keyboardEventKeycode)) == virtKey {
        let wasHeld = service.hyperHeld
        let consumedOther = service.hyperConsumedByOther
        service.hyperHeld = false
        service.hyperConsumedByOther = false
        if let observer = recording {
            if wasHeld { DispatchQueue.main.async { observer(false) } }
        } else if wasHeld && !consumedOther {
            let qp = service.hyperQuickPress
            let dispatcher = service.quickPressDispatcher
            DispatchQueue.main.async { dispatcher?(qp) }
        }
        return nil
    }

    // 3. Companion keyDown while Hyper-held — augment, match, suppress.
    //    In recording mode, let the event pass through so the recorder's
    //    NSEvent monitor can commit it (the recorder folds in hyperFlags
    //    based on `isHyperHeld`). Mark consumed so Hyper-release won't
    //    spuriously fire Quick Press.
    if type == .keyDown && service.hyperHeld {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if recording != nil {
            service.hyperConsumedByOther = true
            return Unmanaged.passUnretained(event)
        }
        var modifiers = Int(event.flags.rawValue & modifierMask)
        modifiers |= service.hyperModifierFlags
        service.hyperConsumedByOther = true
        service.suppressedKeyCodes.insert(keyCode)
        for snapshot in service.snapshots {
            if snapshot.keyCode == keyCode && snapshot.modifierFlags == modifiers {
                let action = snapshot.action
                let dispatcher = service.dispatcher
                DispatchQueue.main.async { dispatcher?(action) }
                break
            }
        }
        return nil
    }

    // 4. Companion keyUp whose keyDown we previously suppressed — consume.
    //    Works regardless of current hyperHeld state (user may release Hyper first).
    if type == .keyUp {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if service.suppressedKeyCodes.remove(keyCode) != nil {
            return nil
        }
    }

    // 5. Normal (Hyper not held) keyDown matching — skipped in recording mode
    //    so existing bindings don't fire while the user is configuring one.
    if type == .keyDown && recording == nil {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = Int(event.flags.rawValue & modifierMask)
        for snapshot in service.snapshots {
            if snapshot.keyCode == keyCode && snapshot.modifierFlags == modifiers {
                let action = snapshot.action
                let dispatcher = service.dispatcher
                DispatchQueue.main.async { dispatcher?(action) }
                return nil
            }
        }
    }

    // Keyboard-lock mode: swallow any keyDown / keyUp / flagsChanged that
    // didn't match. Registered hotkeys above still fire so the user can
    // toggle the lock back off.
    if service.keyboardLocked && (type == .keyDown || type == .flagsChanged || type == .keyUp) {
        return nil
    }

    return Unmanaged.passUnretained(event)
}
