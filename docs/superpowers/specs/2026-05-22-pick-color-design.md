# Pick Color — Design

## Goal

Add a built-in **screen color picker** to AnyDoor's panel. Activating it shows
the macOS system color-sampling loupe (the same magnifier used by SwiftUI's
`ColorPicker` eyedropper). The user clicks a pixel on screen, the color is
copied to the clipboard as an uppercase HEX string, and a bottom-center toast
confirms the result.

## Background

The panel already ships one capture-style action, `OCRProvider` (`屏幕取词`),
which uses `RegionCapture` + `TextRecognizer`, copies to the clipboard, and
reports via `ToastPresenter`. Pick Color follows the same shape but is simpler:
the loupe, clipboard write, and cancellation handling are all provided by a
single native API.

## Approach

Use **`NSColorSampler`** (AppKit, macOS 10.15+). It presents the system loupe,
returns an `NSColor?` via a completion handler, and yields `nil` when the user
cancels. It runs as a system service and does not require the app to hold
Screen Recording permission. No custom overlay window or `screencapture`
invocation is needed.

Alternatives rejected: a hand-built overlay loupe (large effort, worse UX,
needs Screen Recording permission); `screencapture -i` pixel sampling (region
selection, not a magnifier — wrong interaction).

## Components

### 1. `BuiltinItem.pickColor`

New case in the code-defined catalog (`Models/BuiltinItem.swift`):

- `kind`: `.action`
- `title`: `"屏幕取色"`
- `symbol`: `"eyedropper"`
- `defaultOrder`: `975` (between `ocr` 950 and `displaySleep` 1000)
- `requiresAutomation`: `false`
- `feedbackSound`: `nil`

`BuiltinPreferenceSeeder` already diffs `BuiltinItem.allCases` against existing
rows on every launch and appends new items at the end, so existing users get a
`BuiltinPreference` row automatically — visibility, ordering, and hotkey
support come for free.

### 2. `ColorSampler` — new file `Services/ColorSampler.swift`

`@MainActor` helper that adapts `NSColorSampler`'s completion-handler API into
`async`. `NSColorSampler` must be used on the main thread.

```swift
@MainActor
enum ColorSampler {
    /// Presents the system color loupe. Returns nil when the user cancels.
    static func sample() async -> NSColor? {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in
                continuation.resume(returning: color)
            }
        }
    }
}
```

### 3. `PickColorProvider` — new file `Services/Providers/PickColorProvider.swift`

An `actor` conforming to `ActionProvider`, modeled on `OCRProvider`:

- `itemKey`: `.pickColor`
- `permission`: `.notRequired`
- `run()` (absorbs all errors, never propagates — declared `async`, not
  `async throws`):
  1. `await ColorSampler.sample()` — if `nil`, return silently (user cancelled).
  2. Convert the `NSColor` to the sRGB color space via
     `usingColorSpace(.sRGB)`. If that fails, show a failure toast.
  3. Read `redComponent` / `greenComponent` / `blueComponent` (0...1), scale to
     0...255 with rounding, and format as `#RRGGBB` uppercase
     (`String(format: "#%02X%02X%02X", r, g, b)`).
  4. On `MainActor`, write the HEX string to `NSPasteboard.general`
     (`clearContents()` then `setString(_:forType:.string)`).
  5. Show a success toast: `.color(message: "已复制 \(hex)", swatch: swatchColor)`,
     where `swatchColor` is `Color(.sRGB, red:, green:, blue:)` built from the
     same components.

### 4. Toast extension — `Views/ToastView.swift`

`ToastStyle` gains a third case:

```swift
case color(message: String, swatch: Color)
```

`Color` conforms to `Sendable`, so the style still crosses the
provider-actor → `ToastPresenter`-`MainActor` boundary unchanged.

`ToastView` is restructured to switch on the style for its leading element:

- `.success` / `.failure`: SF Symbol image (current behavior — green
  checkmark / red x).
- `.color`: a 16×16 rounded-rectangle swatch filled with `swatch`, with a thin
  `.separator` stroke so light/near-white colors stay visible against the
  toast's material background.

The `message` accessor stays exhaustive over all three cases. The per-style
icon name/color logic moves inline into the `ToastView` leading-element switch
(it no longer needs to be exhaustive over a case that has no SF Symbol).

`ToastPresenter` needs no changes — it already sizes itself to the hosting
view's `fittingSize`, so a slightly wider color toast lays out correctly.

### 5. Registration — `AppDelegate.swift`

Append `PickColorProvider()` to the `providers` array in
`applicationDidFinishLaunching`.

## Data Flow

```
Panel row click / hotkey
  └─> PanelStore.run(.pickColor)            (actionsInFlight guard)
        └─> PickColorProvider.run()
              ├─> ColorSampler.sample()      (MainActor, system loupe)
              │     └─> nil  → return silently (cancelled)
              ├─> NSColor → sRGB → "#RRGGBB"
              ├─> NSPasteboard.general.setString(hex)   (MainActor)
              └─> ToastPresenter.show(.color(...))       (MainActor)
```

## Error Handling

Consistent with `OCRProvider`:

- **Cancellation** (`NSColorSampler` returns `nil`): silent, no toast.
- **Color-space conversion failure**: failure toast `"取色失败"`.
- `run()` never throws; every failure path resolves to a toast or a silent
  return. `PanelStore.run` already guards against overlapping invocations via
  `actionsInFlight`.

## Testing

- Manual: build with `swift run AnyDoor`, open the panel, trigger 屏幕取色,
  pick a known color (e.g. pure red), confirm the clipboard holds `#FF0000`
  and the toast shows the value plus a matching swatch.
- Manual: press Esc during sampling — confirm no toast and no clipboard change.
- Manual: assign a hotkey in the panel settings and confirm it triggers the
  loupe.
- The HEX-formatting conversion (`NSColor` sRGB components → `#RRGGBB`) is the
  only pure logic worth a unit test; if extracted into a small testable
  function, cover black, white, and a mid-tone value.

## Out of Scope

- Color formats other than uppercase HEX (RGB/HSL, lowercase) — single format
  by decision.
- Color history or a recently-picked palette.
- A settings UI for choosing the output format.
