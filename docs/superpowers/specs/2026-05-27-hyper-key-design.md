# Hyper Key — Design

**Date:** 2026-05-27
**Status:** Design approved, pending plan
**Owner:** AnyDoor

## Goal

Add a Raycast-style **Hyper Key** feature to AnyDoor. Users pick one physical key (Caps Lock, a left/right modifier, or F1–F12); pressing it generates the `⌃⌥⌘` (or `⌃⌥⇧⌘`) modifier combination, providing an entire conflict-free shortcut layer. Configured in **Settings → General**. Shortcuts using the Hyper combo render as `✦Key` instead of stacked modifier glyphs.

## Non-goals

- Per-binding Hyper toggle — Hyper is a global input layer, not a per-shortcut attribute.
- Coexistence with Karabiner-Elements / other hidutil consumers — both call sites overwrite the same `UserKeyMapping` and the last writer wins. Documented limitation, not engineered around.
- Multiple simultaneous trigger keys.
- Synthesizing the Hyper modifier flags into other apps' keystrokes. Hyper exists only inside AnyDoor's matching path.

## Approach

`hidutil` remap is the load-bearing primitive (the same approach Raycast uses). At launch and whenever the user picks a trigger, AnyDoor invokes `hidutil property --set` to map the physical trigger key to a fixed virtual F-key (F19 / keyCode 80). F19 is not exposed as a selectable trigger and is unused on real keyboards, so no collision is possible. The existing `HotkeyService` CGEvent tap watches that virtual F-key's `keyDown` / `keyUp`, maintains a "Hyper held" state, and OR-augments incoming `keyDown` events with the Hyper modifier flags before matching them against the existing `HotkeySnapshot` list.

`HotkeySnapshot` storage stays `(keyCode, modifierFlags)`; recording a "Hyper+M" shortcut produces `(M, ⌃⌥⌘⇧)` — bit-identical to recording the same combo with real modifier keys, so the two input methods are equivalent.

The CGEvent tap is the only listener of the virtual F-key; the user's foreground apps never see it.

### Approaches considered

| Approach | Result |
|---|---|
| **A. hidutil-only (chosen)** | Single interception point, reuses existing tap, decoupled from Caps Lock LED quirks and left/right modifier mask differences. Requires cleanup on exit + crash recovery on launch. |
| B. CGEvent tap only (no hidutil) | Caps Lock debouncing is not observable cleanly without first disabling it via hidutil; F1–F12 don't fire `keyDown` when the system "Use F-keys as standard" toggle is off; left/right modifier suppression requires complex event synthesis. Degenerates into A in practice. |
| C. Hybrid (hidutil with tap fallback) | Doubled implementation cost. Fallback path is not actually viable for Caps Lock / F-keys, so its value is low. |

## Data model

### `Models/HyperKey.swift`

```swift
enum HyperKeyTrigger: String, CaseIterable, Sendable, Hashable {
    case none
    case capsLock
    case leftControl, leftShift, leftOption, leftCommand
    case rightControl, rightShift, rightOption, rightCommand
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12

    /// HID usage code (page<<32 | usage) for `hidutil property --set`.
    /// `nil` for `.none`. This is the only keycode representation needed —
    /// once hidutil remap is active, the trigger is observed exclusively as
    /// the virtual F-key, never as its original physical keyCode.
    var hidUsage: UInt64? { ... }

    /// Display label shown in the Settings picker, e.g. "Caps Lock (⇪)".
    /// Language-neutral key glyphs; not part of the L10n catalog.
    var displayLabel: String { ... }
}

enum HyperKeyQuickPress: String, CaseIterable, Sendable, Hashable {
    case doesNothing
    case escape
    case original   // emit the trigger key's original behavior
}
```

### `Services/HyperKeyService.swift`

```swift
@MainActor
@Observable
final class HyperKeyService {
    static let shared = HyperKeyService()

    // --- Read-only state. Persisted in UserDefaults ("hyperKey.*"). ---
    private(set) var trigger: HyperKeyTrigger        // default .none
    private(set) var quickPress: HyperKeyQuickPress  // default .doesNothing
    private(set) var includeShift: Bool              // default true

    /// True iff trigger != .none AND the hidutil mapping is currently applied
    /// AND the HotkeyService tap is running. Drives the green status dot.
    private(set) var isActive: Bool

    /// Set while an apply/clear is in flight. UI dims the picker during this.
    private(set) var isApplying: Bool

    /// Last apply error surface for the UI. Cleared on the next successful op.
    private(set) var lastError: HyperKeyError?

    /// CGEventFlags bitmask Hyper synthesizes: ⌃⌥⌘ or ⌃⌥⇧⌘. Zero when inactive.
    var hyperModifierFlags: Int { ... }

    /// Virtual keyCode (F19 = 80) when active, else -1.
    var virtualKeyCode: Int { ... }

    // --- Mutations. Async + latest-wins. ---

    /// Bumped on every setter call; the apply task captures it and bails if a
    /// newer mutation has already arrived. Prevents stale apply/clear ordering
    /// when the user spams the picker.
    func setTrigger(_ new: HyperKeyTrigger) async
    func setQuickPress(_ new: HyperKeyQuickPress) async
    func setIncludeShift(_ new: Bool) async
}
```

**Mutation contract**:

- All three setters are `async` and run serialized on the `@MainActor`. Each setter:
  1. Bumps an internal monotonic `mutationToken: UInt64`
  2. Persists the new value to UserDefaults immediately
  3. Sets `isApplying = true`
  4. Captures `myToken = mutationToken`
  5. Drives `HyperKeyController` (`apply` / `clear`) as needed
  6. If `mutationToken != myToken` when the await returns, discards the result — a newer setter has superseded this one
  7. On success: updates `isActive`, `hyperModifierFlags`, `virtualKeyCode`, calls `HotkeyService.updateHyperConfig(...)`, clears `lastError`
  8. On failure: forces `trigger = .none`, persists, calls `HotkeyService.updateHyperConfig(virtualKey: -1, ...)`, populates `lastError`
  9. Sets `isApplying = false`

- Setters are `async` precisely because Swift's normal property setters cannot await, which makes the original "side-effects in setter" sketch a race factory. Views call them via `Button { Task { await service.setTrigger(...) } }`-style closures bound to `Picker`'s selection through a computed `Binding` that wraps each set in a `Task`.

- `includeShift` change does **not** call `HyperKeyController` (the virtual key doesn't change); it only recomputes flags and pushes `HotkeyService.updateHyperConfig`.

- `quickPress` change also skips the controller.

```swift
enum HyperKeyError: Error, Sendable {
    case hidutilFailed(stderr: String)
    case tapNotRunning   // CGEvent tap is down (AX denied / failed); refuse to apply.
    case timeout
}
```

### Persistence summary

| Setting | Key | Default | Storage |
|---|---|---|---|
| Trigger | `hyperKey.trigger` | `none` | UserDefaults |
| Quick Press | `hyperKey.quickPress` | `doesNothing` | UserDefaults |
| Include Shift | `hyperKey.includeShift` | `true` | UserDefaults |

No SwiftData migration — existing `KeyBinding` / `BuiltinPreference` schema unchanged. Hotkey records continue to store `(keyCode, modifierFlags)` as raw CGEventFlags bits.

## hidutil controller

### `Services/HyperKeyController.swift`

```swift
actor HyperKeyController {
    static let shared = HyperKeyController()

    /// Apply our single-entry mapping, replacing the previous mapping the
    /// controller wrote. Returns the signature that was written.
    func apply(trigger: HyperKeyTrigger, virtualKey: HyperKeyVirtualKey) async throws -> MappingSignature

    /// Remove **only** the mapping entry whose (src, dst) matches our last
    /// applied signature. Other UserKeyMapping entries (e.g. written by
    /// Karabiner or the user via Terminal) are preserved.
    ///
    /// If the controller has no last-applied signature (clean start),
    /// `reconcile(persistedSignature:)` should be used instead — `clear()`
    /// alone has no idea what's "ours".
    func clear() async throws

    /// Used at launch. The caller passes the signature it last persisted to
    /// UserDefaults; the controller reads the *current* hidutil mapping,
    /// removes that exact entry if present, and ignores anything else.
    /// Safe when AnyDoor has never run, when no mapping exists, or when an
    /// unrelated user has written their own mappings.
    func reconcile(persistedSignature: MappingSignature?) async throws
}

enum HyperKeyVirtualKey { case f19 }   // keyCode 80; reserved enum for future expansion

/// Stable identifier of "the entry we own" in UserKeyMapping. Persisted in
/// UserDefaults across launches so we can recognize our own residue after a
/// crash without nuking anyone else's mappings.
struct MappingSignature: Codable, Sendable, Hashable {
    let src: UInt64   // HIDKeyboardModifierMappingSrc
    let dst: UInt64   // HIDKeyboardModifierMappingDst
}
```

`hidutil` invocation reuses the existing `ShellRunner`. Output is parsed with `JSONSerialization`. **Read-modify-write** semantics:

1. `hidutil property --get UserKeyMapping` to fetch the current array
2. Filter out any entry whose `(src, dst)` matches the signature we're about to remove (clear) or replace (apply)
3. Append the new entry (apply) or skip (clear)
4. `hidutil property --set '{"UserKeyMapping": <new array>}'`

This preserves third-party mappings — the file-replace semantics of `hidutil --set` is now scoped at our process boundary by reading first.

The last-written `MappingSignature` is persisted under `hyperKey.appliedSignature` so the next launch can identify our own residue.

### Lifecycle

**Launch (`AppDelegate.applicationDidFinishLaunching`):**

Order matters — Hyper must never be applied while the CGEvent tap is *not* successfully running, otherwise the user loses their trigger key with no interception in place.

1. Start `HotkeyService` and wait for `eventTap != nil`. If `AXIsProcessTrusted()` is false or `tapCreate` fails, **skip the entire Hyper bootstrap** — leave any persisted signature in UserDefaults untouched so the next successful launch can clean it.
2. Read persisted `MappingSignature?` from `hyperKey.appliedSignature`.
3. Call `HyperKeyController.shared.reconcile(persistedSignature:)` — scoped removal of *our* residue only; preserves third-party UserKeyMapping entries.
4. Read persisted `HyperKeyService` settings.
5. If `trigger != .none`: call `service.setTrigger(trigger)` to re-apply (this writes a fresh signature).
6. Push `HotkeyService.updateHyperConfig(...)` after success.

**Tap state monitoring:**

- `HotkeyService` exposes `isTapRunning: Bool` (computed from `eventTap != nil && CGEvent.tapIsEnabled(tap:)`).
- The watchdog already reports tap loss; on transition `running → not running` while Hyper is active, `HyperKeyService` triggers an emergency `controller.clear()` and sets `lastError = .tapNotRunning`. UI flips to inactive state.
- AX permission revocation is detected via periodic poll in `GeneralSettingsView` (already exists); when revoked, same emergency clear path.

**Runtime change (user edits settings):**

Routed through async setters per the mutation contract above. Specifically:
- `setTrigger(.none)` → controller `clear()`; persisted signature removed.
- `setTrigger(.x)` → controller `apply(trigger: .x, virtualKey: .f19)`; persisted signature updated.
- Before applying, check `HotkeyService.isTapRunning`; if false, populate `lastError = .tapNotRunning` and refuse.
- `setIncludeShift` / `setQuickPress` → no controller call.

**Exit (`applicationShouldTerminate`):**

The Task-and-pray pattern under `applicationWillTerminate` doesn't actually wait for the cleanup. Use the proper hand-off instead:

```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard HyperKeyService.shared.isActive else { return .terminateNow }

    Task {
        // controller.clear() uses Process which we wait on synchronously inside
        // the actor; the await here is on actor reentry, not on a fire-and-forget.
        try? await withTimeout(milliseconds: 500) {
            try await HyperKeyController.shared.clear()
        }
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
}
```

500 ms is enough for `hidutil` to round-trip in normal conditions. If it doesn't, we still terminate — the worst case is a residue that the next launch's `reconcile()` removes.

Also call `controller.clear()` on `NSWorkspace.willPowerOffNotification` via the same `terminateLater` path.

**Signal handlers:**

Removed from the design. Reasons:
- `posix_spawn` is **not** in the macOS async-signal-safe list (sigaction(2) explicitly enumerates the safe set; `posix_spawn` isn't in it).
- A SIGTERM handler that returns simply lets the process keep running; you'd need `_exit(0)` to actually stop, which loses the clean termination path entirely.
- Launch-time `reconcile()` already recovers from any abrupt exit (SIGKILL, panic, force quit).

**Apply failure:**

- Logged via `Logger(subsystem: "dev.bybee.AnyDoor", category: "hyperKey")`.
- `HyperKeyService.trigger` forced to `.none`, persisted; UI picker rebinds to "None" via `@Observable`.
- `lastError` populated; Settings UI shows an inline warning row beneath the Hyper Key picker:
  > ⚠️ 启用失败：辅助功能权限未授予 / hidutil 调用失败。
- `HotkeyService.updateHyperConfig(virtualKey: -1, flags: 0, ...)` ensures the matching path no longer expects a Hyper key.

### Known constraints (documented, not engineered around)

- **Karabiner-Elements coexistence**: `hidutil` `UserKeyMapping` is integral-replace semantics. Each `--set` overwrites the entire mapping. Enabling Hyper Key while Karabiner is also writing mappings results in one side's mapping winning. README will mention.
- **Crash residue with launch-at-login = false**: if AnyDoor is uninstalled while Hyper was active, the mapping persists until reboot. Recovery is `hidutil property --set '{"UserKeyMapping":[]}'`; documented in README, not auto-fixed.
- **Reboot**: `UserKeyMapping` is non-persistent across reboots. Launch-time `apply()` re-establishes it; transparent for launch-at-login users.

## HotkeyService changes

### Tap mask

Add `.keyUp` to the existing mask:

```swift
let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
```

### New configuration entry

```swift
fileprivate nonisolated(unsafe) var hyperVirtualKeyCode: Int = -1
fileprivate nonisolated(unsafe) var hyperModifierFlags: Int = 0
fileprivate nonisolated(unsafe) var hyperQuickPress: HyperKeyQuickPress = .doesNothing

func updateHyperConfig(virtualKey: Int, flags: Int, quickPress: HyperKeyQuickPress) {
    hyperVirtualKeyCode = virtualKey
    hyperModifierFlags = flags
    hyperQuickPress = quickPress
}
```

Re-pushed after `restart()` so the watchdog-driven tap rebuild preserves Hyper config.

### Tap callback state

```swift
fileprivate nonisolated(unsafe) var hyperHeld: Bool = false
fileprivate nonisolated(unsafe) var hyperDownAt: CFTimeInterval = 0
fileprivate nonisolated(unsafe) var hyperConsumedByOther: Bool = false
```

Single-thread access (the HID tap run-loop), no synchronization required.

### Matching logic (additions to `hotkeyCallback`)

```swift
let virtKey = service.hyperVirtualKeyCode

// 1. Hyper trigger keyDown — set held flag, swallow.
if virtKey >= 0 && type == .keyDown
   && Int(event.getIntegerValueField(.keyboardEventKeycode)) == virtKey {
    if !service.hyperHeld {
        service.hyperHeld = true
        service.hyperDownAt = CACurrentMediaTime()
        service.hyperConsumedByOther = false
    }
    return nil
}

// 2. Hyper trigger keyUp — fire Quick Press if no companion key was seen.
if virtKey >= 0 && type == .keyUp
   && Int(event.getIntegerValueField(.keyboardEventKeycode)) == virtKey {
    let wasHeld = service.hyperHeld
    let consumedOther = service.hyperConsumedByOther
    service.hyperHeld = false
    service.hyperConsumedByOther = false
    if wasHeld && !consumedOther {
        let qp = service.hyperQuickPress
        DispatchQueue.main.async { performQuickPress(qp) }
    }
    return nil
}

// 3. Normal keyDown — augment modifiers with Hyper flags while held.
//    Swallow ALL keyDown while held, matched or not (exclusive Hyper layer).
if type == .keyDown {
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    var modifiers = Int(event.flags.rawValue & modifierMask)

    if service.hyperHeld {
        modifiers |= service.hyperModifierFlags
        service.hyperConsumedByOther = true

        for snapshot in service.snapshots {
            if snapshot.keyCode == keyCode && snapshot.modifierFlags == modifiers {
                let action = snapshot.action
                let dispatcher = service.dispatcher
                DispatchQueue.main.async { dispatcher?(action) }
                return nil  // matched: consume
            }
        }
        return nil  // unmatched but Hyper-held: still consume (exclusive layer)
    }

    // Not Hyper-held — fall through to the existing snapshot-match loop,
    // and pass through to the foreground app if no match.
    ...
}

// 4. Companion keyUp during Hyper held — swallow as well, so the foreground
//    app never sees a paired up event for a down it never received.
if type == .keyUp && service.hyperHeld { return nil }
```

**Design points:**
- Storage unchanged. Hyper hits and direct ⌃⌥⌘⇧ hits are bit-equivalent.
- **Exclusive Hyper layer**: while held, every non-trigger `keyDown`/`keyUp` is swallowed. Reasons:
  1. Matches the "conflict-free shortcut layer" promise — pressing Hyper+J when J isn't bound shouldn't leak a `j` keystroke into the foreground app.
  2. Avoids torn down/up pairs (we'd otherwise swallow a `keyDown` on match but let its `keyUp` through, or vice versa).
- Foreground apps still never observe the synthesized Hyper modifier bits — the OR happens only inside our local `modifiers` variable, never on the CGEvent itself.
- Auto-repeat `keyDown` of the trigger lands in branch 1 repeatedly. Idempotent — `hyperDownAt` is preserved.
- Quick Press has **no timeout**: any release without an intervening companion `keyDown` triggers it, matching Raycast.

### Suspend cleanup

`HotkeyService.suspend()` (called during hotkey recording) now also resets Hyper state:

```swift
func suspend() {
    isSuspended = true
    hyperHeld = false
    hyperConsumedByOther = false
    if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
}
```

### Quick Press execution

```swift
@MainActor
private func performQuickPress(_ action: HyperKeyQuickPress) {
    switch action {
    case .doesNothing: return
    case .escape:
        postKeyTap(keyCode: 53)
    case .original:
        emitOriginal(for: HyperKeyService.shared.trigger)
    }
}
```

`.original` is per-trigger:

| Trigger | `.original` implementation |
|---|---|
| Caps Lock | `IOHIDPostEvent` with `kHIDPage_KeyboardOrKeypad` / `kHIDUsage_KeyboardCapsLock` — toggles state + LED. |
| F1–F12 | `CGEvent.post` of `(keyDown, keyUp)` for that physical keyCode. |
| Left/Right modifier | `CGEvent.post` of a brief `.flagsChanged` pulse with the corresponding modifier bit. **MVP-acceptable** — some applications may ignore the synthesized pulse; listed in known limitations. |

## Settings UI

New section in `Views/GeneralSettingsView.swift`, between **Menubar** and **Permissions**:

```
┌─ Hyper Key ──────────────────────────────────────────────────┐
│ Hyper Key 🟢                              [Caps Lock (⇪) ▾]  │
│ 按下 Caps Lock (⇪) 触发 ⌃⌥⇧⌘ 修饰键组合。                       │
│ 使用 Hyper Key 的快捷键会显示为 ✦。                             │
├──────────────────────────────────────────────────────────────┤
│ Quick Press                              [Does Nothing ▾]    │
│ 选择当 Caps Lock (⇪) 被单独按下时执行的动作。                    │
├──────────────────────────────────────────────────────────────┤
│ Include Shift (⇧)                                      [ ●]  │
└──────────────────────────────────────────────────────────────┘
```

**Controls:**
- **Hyper Key row**: `LabeledContent` + `Picker(.menu)` over `HyperKeyTrigger.allCases`. When `trigger != .none`, render `Circle().fill(.green).frame(width: 6)` after the title.
- **Description**: dynamically composed `"按下 \(triggerLabel) 触发 \(modifierString) 修饰键组合。使用 Hyper Key 的快捷键会显示为 ✦。"` Modifier string tracks `includeShift`. Hidden when `trigger == .none`.
- **Quick Press row**: `LabeledContent` + `Picker(.menu)` over `HyperKeyQuickPress.allCases`. `.disabled(true)` when `trigger == .none`. `.original`'s label is contextual: `"切换大写锁定"` for Caps Lock, `"发送 F1"` for F1, etc.
- **Include Shift row**: `Toggle`. `.disabled(true)` when `trigger == .none`.

**Binding pattern**:

Setters are `async` (per the mutation contract), so direct `$hyperKey.trigger` binding doesn't work. Wrap each in a `Binding` that fires a `Task`:

```swift
@State private var hyperKey = HyperKeyService.shared

private var triggerBinding: Binding<HyperKeyTrigger> {
    Binding(
        get: { hyperKey.trigger },
        set: { new in Task { await hyperKey.setTrigger(new) } }
    )
}

// in body:
Picker(selection: triggerBinding) { ... }
    .disabled(hyperKey.isApplying)

if let err = hyperKey.lastError {
    Label { Text(err.userFacingMessage) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
        .foregroundStyle(.orange)
}
```

Same pattern for `quickPressBinding` and `includeShiftBinding`. `isApplying` dims controls during the in-flight controller call to make the latest-wins behavior visible.

### New L10n keys

| Key | zh | en |
|---|---|---|
| `settingsGeneralHyperKeySection` | Hyper Key | Hyper Key |
| `settingsGeneralHyperKeyLabel` | Hyper Key | Hyper Key |
| `settingsGeneralHyperKeyDescription` | 按下 %@ 触发 %@ 修饰键组合。使用 Hyper Key 的快捷键会显示为 ✦。 | Pressing %@ will trigger the %@ modifier keys. Hyper Key shortcuts will be shown with ✦. |
| `settingsGeneralHyperKeyTriggerNone` | 无 | None |
| `settingsGeneralHyperKeyQuickPress` | Quick Press | Quick Press |
| `settingsGeneralHyperKeyQuickPressDescription` | 选择当 %@ 被单独按下时执行的动作。 | Select an action to perform when %@ is pressed without any other keys. |
| `settingsGeneralHyperKeyQuickPressDoesNothing` | 不执行 | Does Nothing |
| `settingsGeneralHyperKeyQuickPressEscape` | Escape | Escape |
| `settingsGeneralHyperKeyQuickPressOriginal` | 保留原始功能 | Original Behavior |
| `settingsGeneralHyperKeyIncludeShift` | 包含 Shift (⇧) | Include Shift (⇧) |

`HyperKeyTrigger.displayLabel` returns static, language-neutral strings (`"Caps Lock (⇪)"`, `"Left Control (⌃)"`, `"F1"`, ...).

## Display: `HotkeyDescriptor`

`HotkeyDescriptor` is a pure value type and stays so. It must not reach into `@MainActor` global state to compute its display form — that breaks Swift 6 strict concurrency (the type is `Sendable` and used off main) and couples a pure model to a UI singleton.

**Refactor**:

- The existing `var displayParts: [String]` is renamed to `func displayParts(hyperFlags: Int = 0) -> [String]`. `hyperFlags == 0` (default) falls back to the existing modifier-glyph path; non-zero with `modifierFlags == hyperFlags` returns `["✦", key]`.
- `displayString` becomes `func displayString(hyperFlags: Int = 0) -> String`.
- Call sites that already render in a `@MainActor` view context (`PanelRowView`, `HotkeyRecorder.label`, `AppShortcutsPopoverView`, etc.) read `HyperKeyService.shared.hyperModifierFlags` at the SwiftUI layer and pass it in. Because the views observe `HyperKeyService.shared` (`@Observable`), they re-render when `trigger` or `includeShift` change — but the model itself stays pure.

```swift
// HotkeyDescriptor.swift
func displayParts(hyperFlags: Int = 0) -> [String] {
    if hyperFlags != 0 && modifierFlags == hyperFlags {
        return ["✦", KeyCodeMap.name(for: keyCode)]
    }
    var parts: [String] = []
    let flags = NSEvent.ModifierFlags(rawValue: UInt(modifierFlags))
    if flags.contains(.control) { parts.append("⌃") }
    if flags.contains(.option)  { parts.append("⌥") }
    if flags.contains(.shift)   { parts.append("⇧") }
    if flags.contains(.command) { parts.append("⌘") }
    parts.append(KeyCodeMap.name(for: keyCode))
    return parts
}

func displayString(hyperFlags: Int = 0) -> String {
    displayParts(hyperFlags: hyperFlags).joined()
}
```

```swift
// In a view:
@State private var hyperKey = HyperKeyService.shared

Text(hotkey.displayString(hyperFlags: hyperKey.hyperModifierFlags))
```

The `hyperFlags: Int = 0` default keeps any non-view callers (logging, debug prints, tests) source-compatible — they get the old plain-modifier rendering.

## Recording: `HotkeyRecorder`

`HotkeyService.suspend()` disables the CGEvent tap during recording but does not affect AppKit event routing. The virtual F-key produced by `hidutil` therefore still arrives at the recorder's `NSEvent.addLocalMonitorForEvents`.

The state machine needs **both** `keyDown` and `keyUp` of the virtual F-key, otherwise a sequence "tap Caps Lock, release, then press M" would still set `hyperArmed = true` and erroneously record `Hyper+M`.

```swift
let virtualKey = HyperKeyService.shared.virtualKeyCode  // -1 when disabled
var hyperHeld = false   // true between virtual keyDown and keyUp

keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let code = Int(event.keyCode)

    if virtualKey >= 0 && code == virtualKey {
        hyperHeld = true
        return nil  // trigger alone is not a hotkey
    }

    let cgFlags = event.cgEvent?.flags ?? []
    var mods = Int(cgFlags.rawValue & modMask)
    if hyperHeld {
        mods |= HyperKeyService.shared.hyperModifierFlags
    }

    // existing ESC / Delete-clear / capture path with `mods` instead of raw
    ...
}

keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
    if virtualKey >= 0 && Int(event.keyCode) == virtualKey {
        hyperHeld = false
        return nil  // swallow; never let the foreground responder see it
    }
    return event
}
```

Both monitors are torn down in `stopRecording()`. The Caps-Lock-tap-then-M case becomes:
1. `keyDown(F19)` → `hyperHeld = true`
2. `keyUp(F19)` → `hyperHeld = false`
3. `keyDown(M)` → captured with raw modifiers only → stored as plain `M`. ✓

**Equivalence guarantee**: recording with Hyper actually held produces the same `(keyCode, modifierFlags)` tuple as pressing the literal modifiers `⌃⌥⌘(⇧)`. Both paths display as `✦Key`.

ESC and Delete (no modifiers) keep their current cancel / clear semantics. They are never composed with `hyperHeld`.

## Acceptance criteria

### Functional
- [ ] Set Hyper Key = Caps Lock, restart AnyDoor. Physical Caps Lock no longer toggles caps state.
- [ ] Record a "Hyper+M" binding to an app — displays as `✦M`.
- [ ] Press Caps Lock + M → binding fires.
- [ ] Press ⌃⌥⌘⇧+M (without Caps Lock) → same binding fires.
- [ ] Press Caps Lock + J (unbound) → no `j` reaches the foreground app; no audible beep; no torn keyUp.
- [ ] Tap Caps Lock alone → Quick Press action fires (Escape / caps toggle / nothing per setting).
- [ ] Tap Caps Lock, release, then press M — recorded as plain `M`, not Hyper+M.
- [ ] Toggle Include Shift OFF: existing `✦M` (stored as `⌃⌥⌘⇧+M`) reverts to `⌃⌥⌘⇧M` rendering; new Hyper+M records as `⌃⌥⌘+M` and renders as `✦M`.
- [ ] Switch trigger to None — Caps Lock restored to system default immediately.
- [ ] `kill -9` the process while Hyper is active → relaunch → only AnyDoor's mapping is reconciled; any pre-existing third-party `UserKeyMapping` entry survives.

### Regression
- [ ] All non-Hyper app shortcuts continue to fire.
- [ ] All built-in toggle / action shortcuts continue to fire.
- [ ] Recorder ESC cancel and Delete clear behaviors unchanged.
- [ ] Pressing physical Caps Lock during recording does not leak caps-lock state changes.

### Permission / failure
- [ ] Launch with AX permission denied: Hyper is **not** applied; Caps Lock works normally; Settings shows the warning row.
- [ ] AX permission revoked while Hyper is active: emergency clear runs; Settings flips to inactive within ~1 s of the next watchdog tick.
- [ ] hidutil call fails (mock by chmod-ing the binary unreadable in dev): `lastError = .hidutilFailed`, trigger forced back to None.

### Race
- [ ] Rapidly toggle the picker A → B → A → None in under 100 ms. Final hidutil state matches the *last* selection; no orphan mapping; `isApplying` returns to false.

### Edge cases
- [ ] Running concurrently with Karabiner-Elements: a Karabiner-written entry remains after AnyDoor applies its own; turning AnyDoor's trigger to None leaves the Karabiner entry intact.
- [ ] Trigger = Left Command → left ⌘ stops working (intentional).
- [ ] App crashes during Hyper-held → next launch starts clean and reconciles only the persisted signature.

## Open questions

Resolved before implementation:

1. **Permission gating** — apply must only happen when the CGEvent tap is verified running. Persisted signature is kept across denied-permission launches so a future grant can clean up properly. **Resolved**: enforce in `HyperKeyService.setTrigger` and at launch.
2. **Unmatched companion key while Hyper held** — swallow at the tap (exclusive Hyper layer). **Resolved**: explicit branch in `hotkeyCallback`, listed in acceptance.
3. **Cleanup ownership** — `HyperKeyController` owns scoped removal via persisted `MappingSignature`; `HyperKeyService` owns the user-facing state machine; `AppDelegate` only wires lifecycle hooks. **Resolved**: each layer has one job.

## Known limitations (carried into implementation)

1. `.original` Quick Press for left/right modifier triggers may be ignored by some applications because the synthesized `.flagsChanged` pulse is brief and lacks accompanying keyboard hardware context.
2. Karabiner-Elements / other `hidutil` consumers **can** coexist (scoped read-modify-write preserves their entries), but if they overwrite the entire `UserKeyMapping` array between AnyDoor's read and AnyDoor's write, the last writer wins for that race window. Not engineered around — `hidutil` doesn't expose a CAS primitive.
3. If AnyDoor is force-quit and uninstalled while Hyper is active, the `hidutil` mapping persists until reboot. Recovery command documented in README.
4. The exclusive Hyper layer (swallow-while-held) means that holding the Hyper trigger then pressing arbitrary keys is *silent* — no key reaches the foreground app. This is intentional and matches Raycast; documented in the in-app description text.
