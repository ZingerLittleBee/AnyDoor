import Cocoa
import PluginInterface
import PluginSupport

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

    /// When true, the CGEvent callback swallows keyboard-originated events
    /// (keys, flags, and NX_SYSDEFINED aux control buttons) before any matching
    /// branch. Used by the "keyboard lock" feature so the keyboard produces no
    /// input. Mouse-originated events still pass through so the lock can be
    /// released from the menu-bar row.
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
        // The lock swallows the trigger's keyUp, so a Hyper combo that armed it
        // would leave hyperHeld stuck and eat every keystroke after unlocking.
        hyperHeld = false
        hyperConsumedByOther = false
        suppressedKeyCodes.removeAll()
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
            // NX_SYSDEFINED — media / brightness / volume / Mission Control
            // keys. CGEventType has no named case; NSEvent.EventType.systemDefined
            // is raw 14. Mouse aux buttons also arrive as NX_SYSDEFINED
            // (subtype 7), so the lock branch distinguishes them by subtype.
            | (CGEventMask(1) << UInt64(NSEvent.EventType.systemDefined.rawValue))
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

// MARK: - Keyboard lock decision

/// Pure policy for the keyboard-lock swallow branch. Extracted so the C tap
/// callback stays thin and the decision can be unit-tested without a live tap.
enum KeyboardLockEventPolicy {
    /// NX_SYSDEFINED (`NSEvent.EventType.systemDefined`). Media, brightness,
    /// volume, mute, play/pause, and Mission Control keys arrive as this type
    /// rather than `keyDown`. `CGEventType` has no named case. Subtype 8
    /// identifies a keyboard media key; subtype 7 is a mouse aux button and
    /// must pass through.
    static let systemDefinedType = CGEventType(
        rawValue: UInt32(NSEvent.EventType.systemDefined.rawValue)
    )!

    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS — keyboard-originated special keys.
    static let auxControlButtonsSubtype: Int16 = 8

    /// NX_SUBTYPE_AUX_MOUSE_BUTTONS — mouse-originated special buttons.
    /// Must never be swallowed: unlocking the keyboard is mouse-only.
    static let auxMouseButtonsSubtype: Int16 = 7

    /// Whether the keyboard-lock tap should drop this event.
    ///
    /// While locked, ordinary key / flag events and keyboard-originated
    /// `NX_SYSDEFINED` aux control buttons (subtype 8) are swallowed. Mouse
    /// aux buttons (subtype 7) and every other type pass through. While
    /// unlocked, nothing is swallowed here — matching stays in the callback.
    nonisolated static func shouldSwallow(
        locked: Bool,
        type: CGEventType,
        systemDefinedSubtype: Int16?
    ) -> Bool {
        guard locked else { return false }
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            return true
        default:
            return type == systemDefinedType
                && systemDefinedSubtype == auxControlButtonsSubtype
        }
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

    // Keyboard lock: the keyboard produces nothing at all — no characters, no
    // modifier-state changes, no hotkeys, no Hyper combos, no Quick Press
    // (which would otherwise synthesize real key events), and no media /
    // function keys (NX_SYSDEFINED aux control buttons). This has to come
    // before every matching branch below, otherwise a match returns first and
    // the lock never sees the event. Releasing the lock is mouse-only, and
    // quitting AnyDoor drops it too, so the keyboard can't be bricked.
    if service.keyboardLocked {
        // Construct NSEvent only on the locked + NX_SYSDEFINED path so the
        // ordinary key hot path stays cheap (the tap has a ~1s budget).
        // A nil NSEvent is a deliberate fail-open: the event passes through,
        // because the one unacceptable failure mode is breaking the mouse.
        let systemDefinedSubtype: Int16? = type == KeyboardLockEventPolicy.systemDefinedType
            ? NSEvent(cgEvent: event)?.subtype.rawValue
            : nil
        if KeyboardLockEventPolicy.shouldSwallow(
            locked: true,
            type: type,
            systemDefinedSubtype: systemDefinedSubtype
        ) {
            return nil
        }
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

    return Unmanaged.passUnretained(event)
}
