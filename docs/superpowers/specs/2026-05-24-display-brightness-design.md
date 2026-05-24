# Display Brightness Control — Design

**Date**: 2026-05-24
**Status**: Approved (design phase)
**Author**: Brainstorming session

## Summary

Add a "屏幕亮度" entry to the AnyDoor menu-bar panel that lets users adjust the
brightness of external DDC/CI displays. Hovering the entry opens a side
popover containing one card per detected external display, each with a
horizontal slider bound to that display's brightness (VCP 0x10). Two global
hotkeys ("亮度 +" / "亮度 −") adjust the brightness of the display under the
mouse cursor by ±1/16 (≈6.25%, matching the macOS system step) and trigger the
native macOS OSD via a private `OSDUIHelper` bridge.

v1 is intentionally scoped to **external DDC/CI displays, brightness only**,
on **both Intel and Apple Silicon** Macs. The MacBook built-in display is
excluded (system F1/F2 already covers it). Per-display volume/contrast and
internal-display control are deferred.

DDC I/O is delegated to [`reitermarkus/DDC.swift`](https://github.com/reitermarkus/DDC.swift)
(MIT, vendored via SPM), which already abstracts the Intel `IOAVService` and
Apple Silicon `Arm64DDC` code paths. AnyDoor wraps it in a small actor that
exposes `read`/`write` against a `DDCBackend` protocol so tests can inject a
mock.

## Goals

- Show one card per external display in a hover popover; per-display
  brightness slider with live drag feedback.
- Two configurable global hotkeys for brightness up/down that affect the
  display under the mouse cursor and surface the native macOS OSD.
- Work on both Intel and Apple Silicon Macs.
- Gracefully handle displays that do not support DDC: card is visible but
  greyed out; slider disabled.
- Hot-plug aware: list updates immediately when displays are connected or
  disconnected.
- Reuse existing AnyDoor infrastructure: `PanelStore`, `BuiltinItem`,
  `BuiltinPreference`, `HotkeyService`, `HoverPopover`, `HotkeyRecorder`.

## Non-goals (v1)

- **No volume control.** Per-display DDC volume (VCP 0x62) is unreliable
  across vendors and only affects the monitor's built-in speakers. Deferred
  to v2.
- **No contrast / RGB / input-source controls.** Out of scope.
- **No MacBook built-in display control.** Requires `DisplayServices`
  private framework; system F1/F2 already works for built-in.
- **No persistence of brightness across launches.** Brightness lives only in
  memory; AnyDoor reads from the display on startup and on hot-plug.
- **No persisted "remember last brightness and restore on connect" behaviour.**
  Avoids the UX trap of overriding manual OSD adjustments.
- **No error dialogs/toasts.** DDC failures are logged; the slider thumb
  briefly greys to signal a transient write failure.
- **No App Store submission compatibility.** The native OSD path uses
  `OSDUIHelper` (private framework); this is acceptable given AnyDoor's
  distribution model.
- **No exposure of the DDC backend from view code.** Views never touch
  `DDC.swift` directly.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Views                                                  │
│  ├─ MenuBarView                                         │
│  │   └─ PanelRowView (kind: .brightnessControl)         │
│  │       └─ hover → HoverPopover                        │
│  │                    └─ BrightnessPopoverView          │
│  │                         └─ ForEach displays:         │
│  │                              DisplayBrightnessCard   │
│  └─ SettingsView → PanelSettingsView                    │
│       (inline expansion: brightness +/- hotkey rows)    │
├─────────────────────────────────────────────────────────┤
│  PanelStore (@MainActor)                                │
│  └─ BuiltinItem.kind extended with .brightnessControl   │
│      dispatch(.brightnessUp/Down) → service.bump(...)   │
├─────────────────────────────────────────────────────────┤
│  DisplayBrightnessService (@MainActor @Observable)      │
│  ├─ displays: [DisplayInfo]                             │
│  ├─ levels:   [CGDirectDisplayID: Float]                │
│  ├─ refresh / setBrightness / bump                      │
│  └─ NSScreen.didChangeScreenParameters observer         │
├─────────────────────────────────────────────────────────┤
│  BrightnessController (actor)                           │
│  └─ probe / read / write via DDCBackend protocol        │
│      ├─ DDCSwiftBackend  (production, wraps DDC.swift)  │
│      └─ MockDDCBackend   (tests)                        │
├─────────────────────────────────────────────────────────┤
│  HotkeyService (existing) + HotkeyAction (extended)     │
│  └─ .brightnessUp / .brightnessDown                     │
├─────────────────────────────────────────────────────────┤
│  OSDBridge (enum, stateless)                            │
│  └─ dlopen OSDUIHelper → native brightness OSD          │
└─────────────────────────────────────────────────────────┘
```

### Layer responsibilities

- **`BrightnessController` (actor)** — serialises I2C writes per displayID;
  retries failed writes once. Knows nothing about UI or screens, only
  display IDs and 0...1 floats. Constructor takes a `DDCBackend` for
  injection.
- **`DisplayBrightnessService` (@MainActor @Observable)** — single source of
  truth for the brightness UI: tracks detected external displays, their
  current brightness, and orchestrates refresh / debounced writes /
  bump-by-delta. Owns the NSScreen observer.
- **`OSDBridge` (enum)** — wraps the private `OSDUIHelper`
  `showImageAtPath:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:` call.
  Stateless; failures silent.
- **`PanelStore`** — adds two cases to `dispatch(_:)`, routes brightness
  hotkeys to the service. Does not own brightness state.
- **Views** — read-only on the service; write only via the service's public
  mutation methods.

## Data model

### Code-defined enum extension

`BuiltinItem` is an enum-of-cases (one case per built-in panel item). Add a
new case and route it to a new `Kind`:

```swift
// Models/BuiltinItem.swift
enum BuiltinItem: String, CaseIterable {
    // ... existing cases (keepAwake, muteAudio, ..., qrcode) ...
    case brightness                       // new
}

extension BuiltinItem {
    enum Kind {
        case toggle
        case action
        case submenu                      // existing: click locks popover
        case brightnessControl            // new: hover-only, click is no-op
    }

    var kind: Kind {
        switch self {
        // ... existing routing ...
        case .brightness: return .brightnessControl
        }
    }
}
```

Position of the `.brightness` case in `defaultOrder`: placed adjacent to
display-related entries (after `.darkMode` is a reasonable default). Final
position is decided at implementation time and can be re-ordered by the user
via Panel Settings.

A new `.brightnessControl` Kind (rather than reusing `.submenu`) is
deliberate: `.submenu`'s click handler locks the popover (`onSubmenu()`,
see `PanelRowView.swift`), whereas the brightness row's click must be a
no-op per the chosen UX. The new Kind keeps that branch local to one
switch case in `PanelRowView`.

`PanelRowView.body`'s `.onTapGesture` switch gains:

```swift
case .brightnessControl: break   // click is intentionally a no-op
```

Hotkey binding for the main row is not applicable — there is no single
"toggle brightness" action. The two ± hotkeys live on separate hidden
`BuiltinPreference` rows (see below).

### SwiftData (`BuiltinPreference`) — no schema change

Reuse the existing `BuiltinPreference` model. Add two hidden preference
entries to store the bump hotkeys (they have no visible row of their own):

| `id`                    | `isVisible` | Purpose                       |
| ----------------------- | ----------- | ----------------------------- |
| `brightness.hotkey.up`  | false       | Stores hotkey for brightness+ |
| `brightness.hotkey.down`| false       | Stores hotkey for brightness− |

Seeded by `BuiltinPreferenceSeeder` on first run if absent.

The Panel Settings UI surfaces these two hidden preferences inline under the
"屏幕亮度" row using the existing `HotkeyRecorder` component.

### Runtime state (in-memory only)

```swift
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String           // CoreDisplay localizedDeviceName, deduped
    let supportsDDC: Bool      // result of first probe
}

@MainActor @Observable
final class DisplayBrightnessService {
    private(set) var displays: [DisplayInfo] = []
    private(set) var levels:   [CGDirectDisplayID: Float] = [:]   // 0...1
    private(set) var isLoading: Set<CGDirectDisplayID> = []
}
```

`levels` is the single source of truth for what the UI shows. It is never
persisted.

## Component contracts

### `DDCBackend` protocol

```swift
protocol DDCBackend: Sendable {
    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16?
    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws
}

struct DDCSwiftBackend: DDCBackend { /* wraps reitermarkus/DDC.swift */ }
struct MockDDCBackend: DDCBackend  { /* test fixture */ }
```

### `BrightnessController`

```swift
actor BrightnessController {
    enum Failure: Error { case ddcUnavailable, writeFailed, readTimeout }

    init(backend: DDCBackend)

    /// One-shot probe: tries a read; success → supports DDC.
    func probe(displayID: CGDirectDisplayID) async -> Bool

    /// 0...1 normalised, or nil if unreadable / unsupported.
    func read(displayID: CGDirectDisplayID) async -> Float?

    /// 0...1 normalised; throws Failure.writeFailed after one retry.
    func write(displayID: CGDirectDisplayID, value: Float) async throws
}
```

Invariants:
- Always operates on VCP 0x10 (brightness).
- Internally converts 0...1 ↔ 0...100 (DDC values are bytes 0-100 for
  brightness on virtually all monitors; max-value VCP query deferred to a
  later iteration if any user reports a quirky display).
- Retries `write` exactly once on failure.
- Read timeout 500 ms (handled at backend or via `Task` timeout).

### `DisplayBrightnessService`

```swift
@MainActor @Observable
final class DisplayBrightnessService {
    static let shared: DisplayBrightnessService

    private(set) var displays: [DisplayInfo]
    private(set) var levels:   [CGDirectDisplayID: Float]
    private(set) var isLoading: Set<CGDirectDisplayID>

    /// Re-enumerates NSScreen.screens, probes/reads DDC per display.
    func refresh() async

    /// Debounced write (~30 ms). Updates `levels` immediately.
    func setBrightness(_ value: Float, for displayID: CGDirectDisplayID)

    /// Hotkey path: ±delta on resolved target. No debounce.
    func bump(_ delta: Float, target: BumpTarget)

    enum BumpTarget { case displayUnderMouse }   // v1: single mode
}
```

Behavioural rules:
- `setBrightness` updates `levels[id]` synchronously; cancels any in-flight
  write Task for that displayID; schedules a new Task that sleeps 30 ms and
  then calls `controller.write`.
- `bump` resolves displayID via mouse cursor → falls back to
  `NSScreen.main` if cursor is over the built-in / unsupported display; if
  fallback is also unsupported, the bump is a no-op.
- `bump` always fires `OSDBridge.showBrightness(newValue, on: displayID)`
  after a successful write.
- `bump` is rate-naturally-limited by user keyboard repeat; no extra
  debouncing.

### `OSDBridge`

```swift
enum OSDBridge {
    /// Best-effort. Silently no-ops on failure.
    static func showBrightness(_ value: Float, on displayID: CGDirectDisplayID)
}
```

- Uses `dlopen` on
  `/System/Library/PrivateFrameworks/OSDUIHelper.framework/OSDUIHelper`
  and `dlsym` to resolve the relevant Obj-C selector.
- Renders the brightness chiclet count (16 chiclets, filled = `round(value*16)`).
- Never throws; never blocks the caller.

### `HotkeyAction` extension

```swift
enum HotkeyAction {
    case toggle(BuiltinKey)
    case action(BuiltinKey)
    case appShortcut(...)
    case brightnessUp         // new
    case brightnessDown       // new
}
```

`PanelStore.dispatch(_:)` adds two cases that call
`DisplayBrightnessService.shared.bump(±1.0/16.0, target: .displayUnderMouse)`.

`PanelStore.rebuildHotkeySnapshots()` reads the two hidden brightness
preferences and emits `HotkeySnapshot`s carrying `.brightnessUp` /
`.brightnessDown`.

## Data flow

### Flow A — User hovers the "屏幕亮度" row

```
1. PanelRowView detects hover (existing HoverGate timing)
2. HoverPopover.show(content: BrightnessPopoverView())
3. BrightnessPopoverView.onAppear → Task { await service.refresh() }
4. service.refresh():
   a. Enumerate NSScreen.screens, filter out CGDisplayIsBuiltin
   b. Resolve each name via CoreDisplay (localizedDeviceName)
   c. Dedupe identical names with suffix " (1)", " (2)", ...
   d. Concurrently probe + read each external display
   e. Update displays / levels → @Observable triggers SwiftUI re-render
5. Cards appear with ProgressView placeholders, fill in as reads complete
```

Cached refresh: if the last refresh succeeded < 30 s ago AND no screen-change
notification has fired since, skip step 4.

### Flow B — User drags a slider

```
1. Slider onChanged(value) → service.setBrightness(value, for: id)
2. service: levels[id] = value           (UI feedback immediate)
3. service: cancel any pending writeTask for id
4. service: spawn writeTask { sleep 30ms; try await controller.write(id, value) }
5. Next onChanged cancels (4) and spawns a fresh one
6. Drag ends → final write lands
7. If write throws: log, briefly grey the slider thumb (transient state on
   the card), no alert
```

### Flow C — Brightness ± hotkey

```
1. CGEvent tap matches the snapshot for .brightnessUp / .brightnessDown
2. DispatchQueue.main.async → PanelStore.dispatch(action)
3. PanelStore → service.bump(±0.0625, target: .displayUnderMouse)
4. service:
   a. Resolve displayID via NSEvent.mouseLocation + NSScreen.screens;
      fallback NSScreen.main; bail if still unsupported.
   b. newValue = clamp(levels[id] + delta, 0...1)
   c. levels[id] = newValue          (popover, if open, updates live)
   d. Task { try await controller.write(id, newValue) }
   e. OSDBridge.showBrightness(newValue, on: id)
```

### Flow D — Display hot-plug

```
1. NSApplication.didChangeScreenParametersNotification observer fires
2. service.refresh() invalidates cache + re-enumerates
3. Removed displays drop out of `displays` and `levels`
4. Open popover re-renders automatically (SwiftUI diff)
```

### Flow E — Application launch

```
AppDelegate.applicationDidFinishLaunching:
1. Build BrightnessController(backend: DDCSwiftBackend())
2. Build DisplayBrightnessService(controller:)  → register as shared
3. Register NSScreen observer inside the service
4. Wire PanelStore dispatcher cases to service.bump
5. Task.detached { await DisplayBrightnessService.shared.refresh() }
   → first hover finds data already cached
```

## UI

### `BrightnessPopoverView`

- Vertical stack of `DisplayBrightnessCard`s separated by 12 pt.
- Outer container width ≈ 320 pt; height auto.

### `DisplayBrightnessCard`

- Background: `.regularMaterial`; cornerRadius 16.
- Title: display name, `.headline`.
- Slider: SwiftUI **system `Slider(value:in:0...1)`** with
  `.controlSize(.large)` and a leading `Image(systemName: "sun.max.fill")`
  outside the slider proper. Native macOS slider styling — does not attempt
  to clone the capsule mockup pixel-for-pixel.
- If `supportsDDC == false`: card visible, slider disabled, opacity 0.4, a
  small "不支持 DDC" caption beneath the title.
- If `isLoading.contains(id)`: the slider is disabled and a small
  `ProgressView()` is rendered to the right of the slider until the first
  read returns; once `levels[id]` is populated the spinner is removed and
  the slider becomes interactive.
- Transient write-failure feedback: thumb tint flashes grey for ~250 ms then
  restores (visual only; no text).

### Empty states

- Zero external displays detected: a single line "未检测到外置显示器", with
  a small `display` SF Symbol, centred.
- External displays found but none DDC-capable: "未检测到支持 DDC 的外置显示器"
  with a one-line hint "DisplayPort/HDMI 通常可用，部分 USB-C 转接线不支持".

### Popover behaviour

- Hover-only open; existing `HoverGate` semantics, 200 ms close delay.
- Click on the panel row itself: no-op (does **not** close the popover).
- ESC closes the popover.

### Settings (Panel tab)

Under the existing "屏幕亮度" row, a chevron-expandable inline section:

```
┌─ 屏幕亮度                       [visible ✓] ≡ ›─┐
│  └─ Expanded:                                   │
│      亮度 +    [⌥⇧F2]   [录入]                  │
│      亮度 −    [⌥⇧F1]   [录入]                  │
└─────────────────────────────────────────────────┘
```

- Reuses `HotkeyRecorder`.
- Recorder calls `HotkeyService.suspend()` / `resume()` as elsewhere.
- Writes to the two hidden `BuiltinPreference` rows via a new
  `PanelStore.setBrightnessHotkey(direction:keyCode:modifierFlags:)` method
  (which saves to SwiftData and calls `rebuildHotkeySnapshots()`).

## Error handling and edge cases

| Scenario                                  | Behaviour                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Display does not support DDC              | `supportsDDC = false`; card visible but greyed out; slider disabled; no further read/write attempts.   |
| DDC read timeout (>500 ms)                | `levels[id]` stays `nil`; slider shows at midpoint but is interactive (drag triggers write normally).  |
| DDC write failure                         | Actor retries once; on second failure, log; thumb greys for ~250 ms; no alert.                         |
| `bump` with mouse on built-in / unsupported| Fallback to `NSScreen.main`. If that is also unsupported, bump becomes a no-op (no OSD, no write).     |
| Hot-unplug during in-flight write         | Actor's next write throws (invalid IOAVService); caught silently; UI removes the card on next refresh. |
| Hot-unplug→replug (displayID reuse/change)| `didChangeScreenParameters` triggers full refresh; stale entries replaced.                             |
| Two displays with identical names         | Deduplicated by appending ` (n)` keyed by `CGDirectDisplayID` ordering for stability.                  |
| MacBook clamshell (lid closed, external)  | `NSScreen.screens` naturally only contains externals; built-in filter is unaffected.                   |
| Accessibility permission missing          | DDC does **not** require it. Hotkey path requires it (existing AnyDoor onboarding handles this).       |
| `OSDBridge.dlopen` fails                  | Silent no-op; brightness change still takes effect at the display.                                     |
| First hover before pre-warm finishes      | Popover shows ProgressView placeholders; cards populate as `refresh()` completes.                      |
| `@Observable` re-render frequency         | `levels` dict is small (typically ≤ 4 external displays); SwiftUI diff cost is negligible.             |

### Out-of-scope failure modes

- Brightness validation (e.g., monitor reports 73 when we wrote 75): not
  checked. We trust the write and update `levels` optimistically.
- VCP max-value handshake (some monitors report a max ≠ 100): not done in
  v1. If a user reports a misbehaving display, add VCP 0x10 max read to a
  later iteration.

## Testing strategy

### Unit tests (XCTest, runnable in CI)

| Module                          | Test focus                                                                                                              |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `BrightnessController`          | Inject `MockDDCBackend`; verify probe behaviour, read normalisation (0...100 → 0...1), write retry on failure, timeout. |
| `DisplayBrightnessService`      | Inject mock controller; verify ① debounce only emits the final write per displayID; ② `bump` clamps to 0...1; ③ NSScreen notification rebuilds `displays`; ④ `displayUnderMouse` falls back to main screen when cursor is over an unsupported display. |
| `PanelStore.dispatch`           | Feed `.brightnessUp` / `.brightnessDown`; assert `bump` called with correct delta and target.                           |
| `DisplayInfo` name deduplication| Three displays named "DELL U2720QM" yield "DELL U2720QM", "DELL U2720QM (1)", "DELL U2720QM (2)", stable across calls.  |

### Manual QA checklist (pre-release)

Captured separately when the implementation lands; covers:

- [ ] Single supported display: hover reads correct brightness; drag updates display.
- [ ] Single unsupported display: card greyed; slider inert.
- [ ] Mixed (one supported, one not): per-card behaviour correct.
- [ ] Hot-plug: list updates; drag-during-unplug does not crash.
- [ ] Hotkey on display A vs display B: routes by cursor position.
- [ ] Hotkey when cursor on built-in: falls back to `NSScreen.main`.
- [ ] Hotkey triggers native OSD overlay.
- [ ] Popover open + hotkey pressed: slider updates live.
- [ ] M1 / M2 / Intel Mac smoke test.
- [ ] MacBook clamshell mode.
- [ ] Restart AnyDoor: brightness on displays is not overwritten.

### Excluded from testing

- Live DDC communication unit tests (require hardware; brittle).
- SwiftUI snapshot tests (low value, high cost for this UI).
- `OSDBridge` tests (private API; silent-failure semantics make assertions meaningless).

## Dependencies

### New SPM dependency

- `https://github.com/reitermarkus/DDC.swift` (MIT) — added to
  `Package.swift`. Copyright/notice surfaced in the project README's
  acknowledgements list and (eventually) in an in-app "About" view.

### System frameworks (already linked or trivially available)

- `IOKit` / `CoreDisplay` / `AppKit` — already used by AnyDoor.
- `OSDUIHelper` (private) — loaded dynamically via `dlopen`; not linked at
  build time.

## Open follow-ups (post-v1)

- VCP 0x10 max-value handshake for non-standard monitors.
- Per-display volume slider (VCP 0x62) — pending validation of how many
  users actually use the monitor's built-in speakers.
- MacBook built-in display support via `DisplayServices`.
- Persist last brightness per display and restore on AnyDoor launch (opt-in).
- `BumpTarget.all` for "adjust every display simultaneously".
- Self-drawn capsule slider that matches the original mockup, if the system
  slider proves too visually inconsistent with the panel aesthetic.
