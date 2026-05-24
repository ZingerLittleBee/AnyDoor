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
native macOS OSD via a private-framework bridge (`OSD.framework`).

v1 is intentionally scoped to **external DDC/CI displays, brightness only**,
on **both Intel and Apple Silicon** Macs. The MacBook built-in display is
excluded (system F1/F2 already covers it). Per-display volume/contrast and
internal-display control are deferred.

DDC I/O is split by architecture: on **Intel**, the
[`reitermarkus/DDC.swift`](https://github.com/reitermarkus/DDC.swift) library
(MIT, SPM) handles the IOKit `i2c` / `IOFramebuffer` path. On **Apple
Silicon**, that library does not work (it uses `IOFBGetI2CInterfaceCount`,
which is not the path arm64 displays use), so AnyDoor includes a
**clean-room `Arm64DDCBackend`** that calls the private
`IOAVServiceCreate` / `IOAVServiceReadI2C` / `IOAVServiceWriteI2C` symbols
directly. The MonitorControl project (GPLv3) is referenced for the *approach*
but no GPL code is copied — function signatures and IORegistry matching
strategy for IOAVService are not copyrightable. Both backends conform to a
single `DDCBackend` protocol; the production typealias is selected per
slice by `#if arch(arm64)` in source code (each slice of a universal
binary compiles independently, so per-slice selection works correctly).
The SPM dependency on DDC.swift is declared unconditionally — see
"Dependencies" for why arch-conditioning the manifest breaks
universal builds.

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
  the private `OSD.framework`; this is acceptable given AnyDoor's
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
│      ├─ Arm64DDCBackend  (Apple Silicon, IOAVService)   │
│      ├─ IntelDDCBackend  (Intel, wraps DDC.swift)       │
│      └─ MockDDCBackend   (tests)                        │
├─────────────────────────────────────────────────────────┤
│  HotkeyService (existing) + HotkeyAction (extended)     │
│  └─ .brightnessUp / .brightnessDown                     │
├─────────────────────────────────────────────────────────┤
│  OSDBridge (enum, stateless)                            │
│  └─ dlopen OSD.framework → OSDManager.sharedManager()   │
│      → native brightness OSD                            │
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
- **`OSDBridge` (enum)** — `dlopen`s `/System/Library/PrivateFrameworks/OSD.framework/OSD`,
  resolves the `OSDManager` class via `NSClassFromString`, calls
  `+sharedManager` then `-showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:`.
  Stateless; failures silent.
- **`PanelStore`** — adds two cases to `dispatch(_:)`, routes brightness
  hotkeys to the service. Does not own brightness state.
- **Views** — read-only on the service; write only via the service's public
  mutation methods.

## Data model

### Code-defined enum extension

`BuiltinItem` is an enum-of-cases (one case per built-in item). Three new
cases and two new `Kind` values are added:

```swift
// Models/BuiltinItem.swift
enum BuiltinItem: String, CaseIterable {
    // ... existing cases (keepAwake, muteAudio, ..., qrcode) ...
    case brightness                       // new: the visible panel row
    case brightnessUp                     // new: hidden, hotkey-only
    case brightnessDown                   // new: hidden, hotkey-only
}

extension BuiltinItem {
    enum Kind {
        case toggle
        case action
        case submenu                      // existing: click locks popover
        case brightnessControl            // new: hover-only, click is no-op
        case hiddenHotkey                 // new: no panel row, hotkey only
    }

    var kind: Kind {
        switch self {
        // ... existing routing ...
        case .brightness:                 return .brightnessControl
        case .brightnessUp, .brightnessDown: return .hiddenHotkey
        }
    }
}
```

Position of `.brightness` in `defaultOrder`: placed after `.darkMode`. Users
can re-order via Panel Settings. `.brightnessUp` / `.brightnessDown` get
sentinel order values and are filtered out of the panel render.

**Why a new `.brightnessControl` Kind** (not reuse `.submenu`): `.submenu`'s
click handler locks the popover (`onSubmenu()` in `PanelRowView.swift`),
whereas the brightness row's click must be a no-op per the chosen UX. New
Kind keeps the branch local.

**Why a new `.hiddenHotkey` Kind** (not "hidden `BuiltinPreference` rows"):
the previous draft stored the ± hotkeys as `isVisible: false` preference
rows, but `PanelStore.entryUsingHotkey()`
(`Sources/AnyDoor/Services/PanelStore.swift:320`) only scans
`topLevelEntries + appShortcutChildren`, which excludes invisible entries.
That would let the brightness hotkeys silently collide with existing app /
built-in hotkeys. Modelling them as real `BuiltinItem` cases that flow
through normal `BuiltinPreference` storage and snapshot rebuild keeps
conflict detection honest.

### Updates to existing exhaustive-switch consumers

Adding new `Kind` cases breaks compile at every exhaustive switch on
`BuiltinItem.Kind`. The full list of consumers (as of `seattle-v1` HEAD)
and the required arm per site:

| Site | Existing arms | Add for `.brightnessControl` | Add for `.hiddenHotkey` |
|---|---|---|---|
| `PanelRowView.swift:52` — `.onTapGesture` switch | `.toggle / .submenu / .action` | `case .brightnessControl: break` (intentional no-op) | `case .hiddenHotkey: break` (defensive; entry never reaches the row) |
| `PanelRowView.swift:86` — `trailing` view switch | toggle shows switch; submenu shows chevron; action shows hotkey | `case .brightnessControl:` — show a small `chevron.right` chevron to advertise hover-popover affordance (same idiom as `.submenu`) | `case .hiddenHotkey: EmptyView()` (never rendered) |
| `PanelSettingsView.swift:83` — `typeBadge` | `.toggle → "系统"`, `.action → "系统 · 动作"`, `.submenu → "系统 · 子菜单"` | `case .brightnessControl: return "系统 · 亮度"` | `case .hiddenHotkey: return "系统 · 全局动作"` (only shown if the row ever surfaces, which it doesn't in v1) |
| `PanelSettingsView.swift:95` — `hotkeyField` row-level recorder gate | matches only `.submenu` → renders empty `Color.clear` | extend the guard: `if item.kind == .submenu || item.kind == .brightnessControl { Color.clear.frame(width: 150) }` — the brightness row gets its hotkey UI inline below (see "Settings (Panel tab)" section), NOT in the row's trailing column | extend the same guard to include `.hiddenHotkey` for symmetry, even though hidden rows aren't rendered |

If any future switch on `Kind` is added, the same pattern applies; the
compiler enforces it.

### Changes to `PanelStore`

```swift
// rebuild(): when assembling topLevelEntries, skip items whose kind is
// .hiddenHotkey. (They still own a BuiltinPreference row for hotkey storage,
// but never appear in the menu bar list nor in PanelSettingsView's grid.)

// entryUsingHotkey(_:excluding:): scan extended to include hidden-hotkey
// entries so brightness ± conflicts with existing app / built-in hotkeys
// are detected:
let hiddenHotkeyEntries = BuiltinItem.allCases
    .filter { $0.kind == .hiddenHotkey }
    .compactMap { makeEntry(for: $0) }
for entry in topLevelEntries + appShortcutChildren + hiddenHotkeyEntries {
    if entry.source == excluding { continue }
    if entry.hotkey == hotkey { return entry }
}

// rebuildHotkeySnapshots(): also emit snapshots for hidden-hotkey
// BuiltinPreferences, with HotkeyAction.brightnessUp / .brightnessDown.
```

Single source of truth: brightness hotkeys live in the same `BuiltinPreference`
table everything else uses; no special-case storage.

### SwiftData (`BuiltinPreference`) — no schema change

`BuiltinPreference` already stores one hotkey per `BuiltinItem` raw value. The
new cases `.brightnessUp` and `.brightnessDown` get their own
`BuiltinPreference` rows, seeded by `BuiltinPreferenceSeeder`. They should
have `isVisible: false` (they own only a hotkey, not a panel row), but
unlike the previous draft they are proper `BuiltinItem` cases, so
`PanelStore` discovers them through `BuiltinItem.allCases`-based scans
(see "Changes to `PanelStore`" above).

**Seeder change required**: `BuiltinPreferenceSeeder.swift:28` currently
hardcodes `isVisible: true`. That has been correct so far because every
existing BuiltinItem is meant to be visible by default. The new
`.hiddenHotkey` kind breaks that assumption — if the seeder runs with the
hardcoded value, the brightness ± rows are persisted with `isVisible: true`,
which is data-semantics-incorrect even though `PanelStore.rebuild()` filters
them out by kind.

Fix: add a computed property on `BuiltinItem`:

```swift
extension BuiltinItem {
    /// Whether this item should default to being shown in the menu bar
    /// panel when first seeded. False only for hidden-hotkey items.
    var defaultVisibility: Bool {
        switch self.kind {
        case .toggle, .action, .submenu, .brightnessControl: return true
        case .hiddenHotkey:                                   return false
        }
    }
}
```

`BuiltinPreferenceSeeder` then uses `item.defaultVisibility` instead of the
literal `true`. This keeps the seeder a single code path and lets future
hidden-hotkey-style items inherit the right default for free.

The Panel Settings UI surfaces these two preferences inline under the
"屏幕亮度" row using the existing `HotkeyRecorder` component (writes go
through a new `PanelStore.setBrightnessHotkey(direction:keyCode:modifierFlags:)`
method that saves to SwiftData and calls `rebuildHotkeySnapshots()`).

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

    /// Monotonic counter per display, incremented on every level mutation
    /// (setBrightness / bump). Used by deferred backfill reads to drop
    /// themselves when a newer user action has superseded them.
    private var levelGeneration: [CGDirectDisplayID: UInt64] = [:]
}
```

`levels` is the single source of truth for what the UI shows. It is never
persisted.

## Component contracts

### `DDCBackend` protocol

```swift
protocol DDCBackend: Sendable {
    /// Fast, side-effect-free check: is the I2C/IOAVService transport
    /// reachable for this display? Does NOT issue a VCP read. Used by
    /// `BrightnessController.probe`.
    func transportReady(displayID: CGDirectDisplayID) -> Bool

    /// Issue a VCP read. May time out independently of `transportReady`.
    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16?

    /// Issue a VCP write. Throws on failure.
    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws
}

#if arch(arm64)
struct Arm64DDCBackend: DDCBackend  { /* clean-room, dlsym IOAVService */ }
typealias ProductionDDCBackend = Arm64DDCBackend
#else
struct IntelDDCBackend: DDCBackend  { /* wraps reitermarkus/DDC.swift */ }
typealias ProductionDDCBackend = IntelDDCBackend
#endif

struct MockDDCBackend: DDCBackend  { /* test fixture */ }
```

Both production backends look up the display's IOAVService /
IOI2CInterface object once and cache it per `CGDirectDisplayID` (refreshed
on screen-change notifications). Cache invalidation on hot-unplug is
handled by the higher-level service via `refresh()`.

### `BrightnessController`

```swift
actor BrightnessController {
    enum Failure: Error { case ddcUnavailable, writeFailed, readTimeout }

    init(backend: DDCBackend)

    /// Transport probe — fast, no VCP query. Returns true iff the display
    /// is reachable via IOAVService / IOI2CInterface. Used to decide whether
    /// to render the card as supported or greyed out. A read or write may
    /// still time out for transient reasons even when this returns true.
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

Service follows the codebase pattern (mirror of
`PanelStore.shared` + `bootstrap(...)`, `ClipboardHistoryStore.shared` +
`bootstrap(...)`):

```swift
@MainActor @Observable
final class DisplayBrightnessService {
    static let shared = DisplayBrightnessService()

    private(set) var displays: [DisplayInfo]
    private(set) var levels:   [CGDirectDisplayID: Float]
    private(set) var isLoading: Set<CGDirectDisplayID>

    /// Called once from AppDelegate. Tests can call this with a
    /// MockDDCBackend-backed controller to override the production wiring.
    func bootstrap(controller: BrightnessController)

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
- `setBrightness` increments `levelGeneration[id]`, updates `levels[id]`
  synchronously, cancels any in-flight write Task for that displayID, and
  schedules a new Task that sleeps 30 ms then calls `controller.write`.
  (The generation bump also invalidates any pending backfill read from a
  prior `bump` — see "Backfill read" below.)
- `bump` resolves displayID via mouse cursor → falls back to
  `NSScreen.main` if cursor is over the built-in / unsupported display; if
  fallback is also unsupported, the bump is a no-op.
- **Baseline when `levels[id] == nil`** (read previously timed out on a
  transport-ready display): `bump` treats the current level as `0.5` for
  the purpose of `clamp(current + delta, 0...1)`. Rationale: keeps hotkey
  UX snappy, avoids ignoring user input; 6.25% nudge from a wrong baseline
  self-corrects within ~4 keypresses.
- **Backfill read after fallback bump** (replacing the naive Flow C step):
  Only triggered when the bump used the `0.5` fallback. The backfill must
  not race with the write nor clobber a fresher optimistic value. Rules:
  1. Maintain `var levelGeneration: [CGDirectDisplayID: UInt64]` on the
     service, incremented on every `setBrightness` / `bump` for a given id.
  2. Capture `gen = levelGeneration[id]` at the moment of the bump.
  3. Schedule the backfill as a continuation of the write Task, not in
     parallel: `Task { try? await controller.write(id, newValue); if
     levelGeneration[id] == gen, let real = await controller.read(id),
     levelGeneration[id] == gen { levels[id] = real } }`. The double
     generation check brackets the read so an intervening bump always
     wins.
  4. If `controller.write` throws, do not attempt the backfill (the
     display is in an unknown state; next user action will set it).
- **OSD timing**: `bump` fires `OSDBridge.showBrightness(newValue, on: id)`
  *optimistically*, immediately after spawning the write Task — not after
  the write resolves. Rationale: DDC writes can take 50-200 ms; deferring
  the OSD until after `write` returns makes the chiclet feel laggy relative
  to the keystroke. If the write later fails, we do NOT undo the OSD
  (acceptable: nudges are tiny and the OSD is transient).
- `bump` is rate-naturally-limited by keyboard repeat; no extra
  debouncing.

### `OSDBridge`

```swift
enum OSDBridge {
    /// Best-effort. Silently no-ops on failure.
    static func showBrightness(_ value: Float, on displayID: CGDirectDisplayID)
}
```

- Loads `/System/Library/PrivateFrameworks/OSD.framework/OSD` via `dlopen`.
  Verified path on macOS 26.5 (`OSDUIHelper.framework` /
  `OSDUIHub.framework` from older macOS docs do **not** exist on current
  systems). The on-disk binary is a stub symlink resolved from the dyld
  shared cache; `dlopen` succeeds because dyld services symbols from the
  cache rather than the on-disk file.
- Resolves `OSDManager` via `NSClassFromString("OSDManager")`, calls
  `+sharedManager` (returns an `NSObject` that internally manages the XPC
  connection to `OSDUIHelper.app` in `/System/Library/CoreServices`),
  then invokes the chiclet display selector
  `showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:`.
- Brightness uses OSD image id `OSDGraphic.brightness` (raw value `1` in
  the published private enum). Chiclet count = 16,
  `filled = round(value * 16)`.
- Selector name confirmed against MonitorControl's bridging header.
  `showImageAtPath:withText:...` is a *different* selector used for
  text-bearing OSDs and is **not** used here.
- Never throws; never blocks the caller. If `dlopen`, `NSClassFromString`,
  `+sharedManager`, or `responds(to:)` fails (e.g., the framework path or
  selector changes in a future macOS), the call returns silently and the
  DDC write still takes effect at the display.

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

Hover-popover plumbing in AnyDoor lives in `MenuBarView`, not
`PanelRowView` (see `Sources/AnyDoor/Views/MenuBarView.swift:117-118` for
the existing `.submenu` registration). The brightness row plugs into the
same machinery:

```
1. MenuBarView's hover-trigger logic registers a trigger frame for any
   built-in row whose kind is .submenu OR .brightnessControl.
2. When the cursor enters that frame and the HoverGate delay elapses,
   MenuBarView sets activeHoverTarget = .brightnessControl(.brightness)
   (new HoverPopoverTarget case).
3. mountPopoverContent gains a new branch:
       case .brightnessControl(.brightness):
           HoverPopover.show(content: BrightnessPopoverView())
4. BrightnessPopoverView.onAppear → Task { await service.refresh() }
5. service.refresh():
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
   b. usedFallback = (levels[id] == nil)
   c. baseline = levels[id] ?? 0.5
   d. newValue = clamp(baseline + delta, 0...1)
   e. levelGeneration[id] &+= 1; let gen = levelGeneration[id]
   f. levels[id] = newValue          (popover updates live if open)
   g. OSDBridge.showBrightness(newValue, on: id)   (optimistic; pre-await)
   h. Task {
         do {
            try await controller.write(id, newValue)
         } catch { return }                       // no backfill on failure
         guard usedFallback, levelGeneration[id] == gen else { return }
         guard let real = await controller.read(id) else { return }
         guard levelGeneration[id] == gen else { return }   // newer bump wins
         levels[id] = real
      }
```

### Flow D — Display hot-plug

```
1. NSApplication.didChangeScreenParametersNotification observer fires
2. service.refresh() invalidates cache + re-enumerates
3. Removed displays drop out of `displays` and `levels`
4. Open popover re-renders automatically (SwiftUI diff)
```

### Flow E — Application launch

Mirrors the existing `PanelStore.shared.bootstrap(...)` /
`ClipboardHistoryStore.shared.bootstrap(...)` pattern:

```
AppDelegate.applicationDidFinishLaunching:
1. let backend = ProductionDDCBackend()              // arch-selected at compile time
2. let controller = BrightnessController(backend: backend)
3. DisplayBrightnessService.shared.bootstrap(controller: controller)
   // bootstrap() also installs the NSScreen observer
4. PanelStore dispatcher already wired in existing flow; the new
   HotkeyAction cases route to DisplayBrightnessService.shared.bump(...)
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
| Display has no DDC transport (`transportReady == false`) | `supportsDDC = false`; card visible but greyed out; slider disabled; no further read/write attempts. This is the only path that sets `supportsDDC = false`. |
| DDC value read timeout (>500 ms) on a transport-ready display | `supportsDDC` stays `true`; `levels[id]` stays `nil`; slider shows at midpoint but remains interactive (drag triggers write normally — many monitors accept writes but refuse VCP reads). Hotkey bump uses 0.5 as baseline (see service rules) and schedules a backfill read after the write. |
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
| `DisplayBrightnessService`      | Inject mock controller; verify ① debounce only emits the final write per displayID; ② `bump` clamps to 0...1; ③ NSScreen notification rebuilds `displays`; ④ `displayUnderMouse` falls back to main screen when cursor is over an unsupported display; ⑤ nil-baseline bump uses 0.5 and only backfills when subsequent generation matches (test with: a) successful backfill, b) interleaved bump invalidates backfill, c) interleaved setBrightness invalidates backfill, d) write failure suppresses backfill). |
| `BuiltinPreferenceSeeder`       | After adding `.brightnessUp` / `.brightnessDown`, verify their seeded `BuiltinPreference` rows have `isVisible == false` (via the new `defaultVisibility` property), and existing items still seed `isVisible == true`. |
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
  `Package.swift` **unconditionally**. SwiftPM's `Package.Dependency`
  conditions only support `.platforms(...)`, not `arch`, and `#if arch(...)`
  in a `Package.swift` manifest is evaluated against the **host
  architecture**, not per slice. `scripts/release.sh:132` does a universal
  build (`swift build -c release --arch arm64 --arch x86_64`), so any
  host-conditioned manifest would silently drop the dependency from one
  slice and break the universal release. The dependency is therefore
  unconditional; the *usage* lives behind `#if !arch(arm64)` in the source
  files that wrap it (`IntelDDCBackend`). On an arm64-only build the
  resulting binary contains no DDC.swift symbols (dead-code stripped),
  with only a small manifest-resolution overhead at build time.
  Copyright/notice surfaced in README's acknowledgements list and in the
  eventual in-app "About" view.

### New in-repo code (no third-party dependency)

- `Arm64DDCBackend` — ~150-200 lines of Swift, clean-room implementation of
  IOAVService-based DDC over I2C for Apple Silicon. Uses public IOKit calls
  plus `dlsym`-loaded `IOAVServiceCreate`, `IOAVServiceReadI2C`,
  `IOAVServiceWriteI2C` private symbols. The MonitorControl project's
  Arm64DDC.swift is GPLv3 and is **not** copied; we reference only its
  approach, which is non-copyrightable.

### System frameworks (already linked or trivially available)

- `IOKit` / `CoreDisplay` / `AppKit` — already used by AnyDoor.
- `OSD.framework` (private) — loaded dynamically via `dlopen` at
  `/System/Library/PrivateFrameworks/OSD.framework/OSD`; not linked at
  build time. Class lookup (`NSClassFromString("OSDManager")`), shared
  instance, and selector resolution are each guarded so framework path,
  class, or selector changes in a future macOS degrade gracefully (silent
  no-op; DDC write still lands).

## Open follow-ups (post-v1)

- VCP 0x10 max-value handshake for non-standard monitors.
- Per-display volume slider (VCP 0x62) — pending validation of how many
  users actually use the monitor's built-in speakers.
- MacBook built-in display support via `DisplayServices`.
- Persist last brightness per display and restore on AnyDoor launch (opt-in).
- `BumpTarget.all` for "adjust every display simultaneously".
- Self-drawn capsule slider that matches the original mockup, if the system
  slider proves too visually inconsistent with the panel aesthetic.
