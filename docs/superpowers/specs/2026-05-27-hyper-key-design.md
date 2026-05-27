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

`hidutil` remap is the load-bearing primitive (the same approach Raycast uses). At launch and whenever the user picks a trigger, AnyDoor invokes `hidutil property --set` to map the physical trigger key to a virtual F-key (F19 by default; F20 when the trigger itself is F19). The existing `HotkeyService` CGEvent tap watches that virtual F-key's `keyDown` / `keyUp`, maintains a "Hyper held" state, and OR-augments incoming `keyDown` events with the Hyper modifier flags before matching them against the existing `HotkeySnapshot` list.

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
    /// `nil` for `.none`.
    var hidUsage: UInt64? { ... }

    /// CGEventTap-side keyCode for the physical key (used by HotkeyRecorder when
    /// detecting trigger press during recording).
    var physicalKeyCode: Int? { ... }

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

    var trigger: HyperKeyTrigger       // persisted UserDefaults "hyperKey.trigger"
    var quickPress: HyperKeyQuickPress // persisted "hyperKey.quickPress"
    var includeShift: Bool             // persisted "hyperKey.includeShift", default true

    /// True iff trigger != .none AND hidutil mapping was applied successfully.
    var isActive: Bool { ... }

    /// CGEventFlags bitmask Hyper synthesizes: ⌃⌥⌘ or ⌃⌥⇧⌘. Zero when inactive.
    /// HotkeyDescriptor.displayString reads this to decide ✦ rendering.
    var hyperModifierFlags: Int { ... }

    /// Virtual keyCode that the trigger is mapped to. -1 when inactive.
    /// Fixed at F19 (keyCode 80) — F19 is not in `HyperKeyTrigger`'s allowed
    /// trigger set and is unused on real keyboards, so no allocation collision
    /// is possible.
    var virtualKeyCode: Int { ... }

    func apply() async   // (re)apply hidutil mapping + push config to HotkeyService
    func restore() async // clear hidutil mapping; safe to call repeatedly
}
```

Side-effects (calling `apply()` / `restore()` + `HotkeyService.updateHyperConfig(...)`) live in the property setters, not in views.

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

    func apply(trigger: HyperKeyTrigger, virtualKey: HyperKeyVirtualKey) async throws
    func clear() async throws        // resets UserKeyMapping to []
    func isStale() async -> Bool     // current hidutil property vs. our last-applied state
}

enum HyperKeyVirtualKey { case f19 }   // keyCode 80; reserved enum to allow future expansion
```

Underlying call form:

```bash
hidutil property --set '{"UserKeyMapping":[
  {"HIDKeyboardModifierMappingSrc": <hidUsage(trigger)>,
   "HIDKeyboardModifierMappingDst": <hidUsage(virtualKey)>}
]}'
```

`hidutil` invocation reuses the existing `ShellRunner`. Output is parsed with `JSONSerialization` for `isStale()` (compare returned `UserKeyMapping` array to our intended mapping).

### Lifecycle

**Launch (`AppDelegate.applicationDidFinishLaunching`):**
1. Unconditional `HyperKeyController.shared.clear()` — recovers from crashes that left a stale mapping.
2. Read persisted `HyperKeyService` settings.
3. If `trigger != .none`: `controller.apply(trigger:, virtualKey:)`.
4. Push virtual keyCode + modifier flags + quick-press to `HotkeyService.updateHyperConfig(...)`.

**Runtime change (user edits settings):**
- `trigger` change → `controller.apply()` or `controller.clear()`.
- `includeShift` change → no hidutil call (virtual key unchanged); just `HotkeyService.updateHyperConfig` + recompute `hyperModifierFlags`.
- `quickPress` change → no hidutil call; just `HotkeyService.updateHyperConfig`.

**Exit (`applicationWillTerminate` + `NSWorkspace.willPowerOffNotification`):**
- `Task { try await controller.clear() }` with a 200 ms timeout cap.

**Signal handler (SIGTERM / SIGINT):**
- Registered `signal()` handler that `posix_spawn`s `hidutil property --set '{"UserKeyMapping":[]}'`. No Swift async on the signal path.

**Apply failure:**
- `HyperKeyService.trigger` is forced back to `.none`; UI picker rebinds to "None"; error logged via `Logger(subsystem: "dev.bybee.AnyDoor", category: "hyperKey")`.

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

// 3. Normal keyDown matching — OR Hyper flags onto incoming event flags while held.
if type == .keyDown {
    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
    var modifiers = Int(event.flags.rawValue & modifierMask)
    if service.hyperHeld {
        modifiers |= service.hyperModifierFlags
        service.hyperConsumedByOther = true
    }
    // existing snapshot match loop, unchanged
}
```

**Design points:**
- Storage unchanged. Hyper hits and direct ⌃⌥⌘⇧ hits are bit-equivalent.
- Augmentation is matching-side only — un-matched events pass through with their original flags. Foreground apps never see synthesized Hyper modifiers.
- Auto-repeat `keyDown` of the trigger reaches branch 1 repeatedly. Idempotent — `hyperDownAt` is preserved.
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

**Binding pattern** (matches existing `LocalizationManager` usage in `GeneralSettingsView`):

```swift
@State private var hyperKey = HyperKeyService.shared
// in body:
@Bindable var hyperKey = hyperKey
Picker(selection: $hyperKey.trigger) { ... }
Picker(selection: $hyperKey.quickPress) { ... }
Toggle(isOn: $hyperKey.includeShift) { ... }
```

`apply()` / `restore()` calls live in `HyperKeyService` setters, not in `.onChange` modifiers.

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

Only `displayParts` is touched. Structure and storage are unchanged:

```swift
var displayParts: [String] {
    let hyperFlags = HyperKeyService.shared.hyperModifierFlags
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
```

Since `HyperKeyService` is `@Observable`, views rendering hotkey badges re-invalidate when `trigger` / `includeShift` change. If a specific surface fails to refresh, add `.id(hyperKey.trigger)` / `.id(hyperKey.includeShift)` as a targeted fix — **not** prophylactically.

## Recording: `HotkeyRecorder`

`HotkeyService.suspend()` disables the CGEvent tap during recording but does not affect AppKit event routing. The virtual F-key produced by `hidutil` therefore still arrives at the recorder's `NSEvent.addLocalMonitorForEvents`.

```swift
let virtualKey = HyperKeyService.shared.virtualKeyCode
var hyperArmed = false

keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    let code = Int(event.keyCode)

    if virtualKey >= 0 && code == virtualKey {
        hyperArmed = true
        return nil  // swallow; trigger alone is not a hotkey
    }

    let cgFlags = event.cgEvent?.flags ?? []
    var mods = Int(cgFlags.rawValue & modMask)
    if hyperArmed {
        mods |= HyperKeyService.shared.hyperModifierFlags
    }

    // existing ESC / Delete-clear / capture path with `mods` instead of raw
    ...
}
```

**Equivalence guarantee**: recording with Hyper produces the same `(keyCode, modifierFlags)` tuple as pressing the literal modifiers `⌃⌥⌘(⇧)`. Both paths display as `✦Key`.

ESC and Delete (no modifiers) keep their current cancel / clear semantics. They are never composed with `hyperArmed`.

## Acceptance criteria

### Functional
- [ ] Set Hyper Key = Caps Lock, restart AnyDoor. Physical Caps Lock no longer toggles caps state.
- [ ] Record a "Hyper+M" binding to an app — displays as `✦M`.
- [ ] Press Caps Lock + M → binding fires.
- [ ] Press ⌃⌥⌘⇧+M (without Caps Lock) → same binding fires.
- [ ] Tap Caps Lock alone → Quick Press action fires (Escape / caps toggle / nothing per setting).
- [ ] Toggle Include Shift OFF: existing `✦M` (stored as `⌃⌥⌘⇧+M`) reverts to `⌃⌥⌘⇧M` rendering; new Hyper+M records as `⌃⌥⌘+M` and renders as `✦M`.
- [ ] Switch trigger to None — Caps Lock restored to system default immediately.
- [ ] `kill -9` the process while Hyper is active → relaunch → launch-time `clear()` restores Caps Lock before re-applying.

### Regression
- [ ] All non-Hyper app shortcuts continue to fire.
- [ ] All built-in toggle / action shortcuts continue to fire.
- [ ] Recorder ESC cancel and Delete clear behaviors unchanged.
- [ ] Pressing physical Caps Lock during recording does not leak caps-lock state changes.

### Edge cases
- [ ] Running concurrently with Karabiner-Elements — last writer wins on `UserKeyMapping`; README mentions this.
- [ ] Trigger = Left Command → left ⌘ stops working (intentional).
- [ ] App crashes during Hyper-held → next launch starts clean.

## Open questions

None at design time.

## Known limitations (carried into implementation)

1. `.original` Quick Press for left/right modifier triggers may be ignored by some applications because the synthesized `.flagsChanged` pulse is brief and lacks accompanying keyboard hardware context.
2. Karabiner-Elements / other `hidutil` consumers cannot coexist cleanly with AnyDoor's Hyper Key.
3. If AnyDoor is force-quit and uninstalled while Hyper is active, the `hidutil` mapping persists until reboot. Recovery command documented in README.
