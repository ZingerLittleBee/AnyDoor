# OCR Screen Text — Design

**Date**: 2026-05-22
**Status**: Approved (design phase)
**Author**: Brainstorming session

## Summary

Add an OCR action to the AnyDoor panel. When triggered, the user drags a
selection rectangle over any part of the screen (the native macOS region
selection UI). The selected region is recognized with the built-in Vision
text recognition engine, the recognized text is written to the system
clipboard, and a small transient toast at the bottom-center of the screen
reports success or failure. The toast auto-dismisses after ~1 second.

The feature reuses the existing `BuiltinItem` / `ActionProvider`
infrastructure, so the OCR entry can be reordered, hidden, and assigned a
global hotkey from the panel settings exactly like any other action item
(e.g. "截图到剪贴板").

## Goals

- Trigger via the panel row or an assignable global hotkey.
- Capture an arbitrary screen region using the native macOS selection UI.
- Recognize text with the macOS Vision framework (no third-party engine).
- Recognize mixed Chinese + English text (explicit `zh-Hans` + `en-US`
  recognition language list).
- Write the recognized text to `NSPasteboard.general`.
- Show a non-interactive toast at the bottom-center of the screen reporting
  success or failure, auto-dismissing after ~1 second.
- Provide a reusable `ToastPresenter` UI primitive that other features can
  use later.

## Non-Goals

- No full-screen OCR and no OCR of a pre-existing clipboard image; region
  selection is the only input source in this iteration.
- No custom selection overlay (ScreenCaptureKit); the native `screencapture`
  tool is used.
- No translation, no text post-processing beyond joining recognized lines.
- No user-configurable recognition languages or recognition level; both are
  fixed (see Clarifications). Configurability is deferred.
- No toast queue / stacking; a new toast replaces the current one.
- No history of past recognitions.
- No preview of the recognized text inside the toast; the toast shows status
  only.

## Clarifications Captured

| Topic | Decision |
|-------|----------|
| Input source | Interactive region selection via `screencapture -i -s` (selection-only; `-s` disables the spacebar window-capture mode) |
| Capture mechanism | `screencapture -i -s <tempfile>` to a temp PNG, decoded to `CGImage`, temp file deleted afterward |
| Capture timeout | None — the interactive selection runs with no watchdog; `ShellRunner` is extended to accept an optional/`nil` timeout (see ShellRunner change) |
| Cancellation (Esc) | Detected by **temp-file absence** after the command, not by exit code. Silent no-op — no toast, clipboard untouched |
| Control modifier during capture | If the user holds Control while selecting, `screencapture` writes the capture to the clipboard instead of the file (native, non-suppressible behavior). No file is produced, so OCR treats it as a cancellation (silent). Accepted edge case |
| OCR engine | Vision framework, modern Swift API `RecognizeTextRequest` |
| Recognition languages | Explicit `recognitionLanguages = [Locale.Language("zh-Hans"), Locale.Language("en-US")]`; `automaticallyDetectsLanguage = false`; `recognitionLevel = .accurate` |
| Multi-line handling | One string per recognized observation, joined top-to-bottom with `\n` |
| Empty result | Failure toast "未识别到文字"; clipboard untouched |
| Concurrency guard | `PanelStore.run(_:)` gains a per-item in-flight guard (mirroring the existing `toggle` guard) so a re-trigger while OCR is mid-flight is dropped |
| Toast content | Status only (icon + text); no recognized-text preview |
| Toast position | Bottom-center of the screen containing the mouse cursor |
| Toast lifetime | Fade-in 0.15s → hold 1.0s → fade-out 0.2s |
| Re-trigger | New toast replaces the current one (cancel pending dismiss, reset timer) |
| Permission | `OCRProvider.permission = .notRequired` |
| Menu integration | New `BuiltinItem.ocr` with `kind = .action` |
| Panel ordering | `defaultOrder = 950` positions OCR after "截图到剪贴板" on fresh installs only. Existing installs receive the row appended at the end of the panel (the seeder's standing contract); the user can reorder it in panel settings. No migration |

## Architecture

Five new units plus small edits to four existing files. Each new unit has a
single responsibility and a narrow interface.

```
                 hotkey / panel row
                        │
                        ▼
        ┌───────────────────────────────┐
        │  OCRProvider (actor)          │   ActionProvider
        │  run():                       │
        │   1. RegionCapture.capture()  │──► CGImage? (nil = cancelled)
        │   2. TextRecognizer.recognize │──► [String]
        │   3. NSPasteboard write       │
        │   4. ToastPresenter.show()    │
        └───────────────────────────────┘
                        │ await (MainActor hop)
                        ▼
        ┌───────────────────────────────┐
        │  ToastPresenter (@MainActor)  │  owns one NSPanel
        │  show(ToastStyle)             │  hosts ToastView
        └───────────────────────────────┘
```

### New files

```
Sources/AnyDoor/
├── Services/
│   ├── TextRecognizer.swift      # Vision wrapper, pure, testable
│   ├── RegionCapture.swift       # screencapture -i wrapper
│   └── Providers/
│       └── OCRProvider.swift     # ActionProvider orchestrating the flow
└── Views/
    ├── ToastPresenter.swift      # @MainActor singleton, owns the toast NSPanel
    └── ToastView.swift           # SwiftUI content (icon + text + material)
```

### Modified files

- `Models/BuiltinItem.swift` — add `case ocr`:
  - `kind = .action`
  - `title = "屏幕取词"`
  - `symbol = "text.viewfinder"`
  - `defaultOrder = 950` (positions OCR after `.screenshot` at 900 — see the
    Panel Ordering note below)
  - `requiresAutomation = false`
  - `feedbackSound = nil`
- `AppDelegate.swift` — register `OCRProvider()` in the `providers` array.
- `Services/ShellRunner.swift` — make the timeout optional so an interactive
  subprocess can run without the watchdog (see ShellRunner change below).
- `Services/PanelStore.swift` — add a per-item in-flight guard to `run(_:)`
  (see Action In-Flight Guard below).
- `BuiltinPreferenceSeeder` — no code change required; it iterates
  `BuiltinItem.allCases`, so the new case is seeded automatically.

### Panel Ordering (existing vs fresh installs)

`BuiltinPreferenceSeeder` only applies `defaultOrder` on a **fresh install**
(`existing.isEmpty`). For an install that already has `BuiltinPreference`
rows, the seeder appends every new `BuiltinItem` at the end of the panel
(`maxOrder + 100`, incrementing). Therefore:

- **Fresh install** — OCR appears right after "截图到剪贴板".
- **Existing install** — OCR appears at the bottom of the panel; the user can
  drag it anywhere in panel settings.

This matches how every previously-added built-in behaved and keeps the
seeder's documented contract intact. No migration is written. `defaultOrder`
is still defined because it governs the fresh-install seeding order (every
`BuiltinItem` case must supply one). `MigrationTests` continues to assert the
append-at-end behavior for existing installs.

### ShellRunner change

`ShellRunner.run` currently defaults to a 5-second timeout and `terminate()`s
the subprocess when it elapses. An interactive `screencapture` selection
routinely takes longer than 5 seconds, which would kill the user's selection
mid-drag. The fix: make the parameter optional —

```
static func run(_ path: String, args: [String] = [],
                timeout: TimeInterval? = 5) async throws -> String
```

When `timeout` is `nil`, the watchdog loop is skipped and the runner simply
waits for the process to exit. All existing call sites are unaffected (the
`5` default is unchanged). `RegionCapture` passes `timeout: nil`.

## Component Details

### `TextRecognizer`

Pure, UI-free, shell-free. The only unit with an automated test.

```
enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> [String]
}
```

- Uses Vision's modern Swift API `RecognizeTextRequest` (verified against the
  macOS 26 SDK `Vision.swiftinterface`):
  - `recognitionLevel = .accurate`
  - `recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]`
    — the property is `[Foundation.Locale.Language]`, **not** `[String]`.
  - `automaticallyDetectsLanguage = false` — keep the explicit language list
    authoritative (the SDK default is `false`, default language `en-US`;
    setting the list explicitly is what enables Chinese recognition).
- Runs `try await request.perform(on: cgImage)` → `[RecognizedTextObservation]`.
- For each observation, takes `observation.transcript` (the recognized text
  string; available macOS 26+).
- Orders results top-to-bottom by observation bounding-box origin Y
  (descending — Vision's normalized coordinate space has Y increasing upward).
- Throws on a Vision engine error. An empty result is `[]`, not an error.

### `RegionCapture`

Wraps the native selection tool. Owns the temp-file lifecycle.

```
enum RegionCapture {
    /// Returns nil when the user cancels the selection.
    static func captureRegion() async throws -> CGImage?
}
```

- Builds a unique temp path with a `.png` extension under
  `FileManager.default.temporaryDirectory`.
- Runs `/usr/sbin/screencapture` with `["-i", "-s", <tempPath>]` via
  `ShellRunner`, passing `timeout: nil` (no watchdog — the user controls how
  long the selection takes).
  - `-s` restricts the interaction to mouse selection, disabling the
    spacebar window-capture mode.
- Outcome classification after the command:

  | Signal | Meaning | Result |
  |--------|---------|--------|
  | `ShellRunner` throws a process-launch error (not `BuiltinError.shellFailed`) | screencapture could not run | rethrow → failure toast |
  | `BuiltinError.shellFailed` (non-zero exit) **and** temp file absent | user cancelled (screencapture's cancel exit code is undocumented and unreliable) | return `nil` |
  | No throw / `shellFailed`, temp file **absent** | user cancelled, or held Control to copy to clipboard | return `nil` |
  | Temp file **present** but undecodable to `CGImage` | corrupt/empty capture | throw `OCRError.imageDecodeFailed` → failure toast |
  | Temp file **present** and decodable | success | return the `CGImage` |

  Rationale: `screencapture`'s exit code on cancellation is not documented and
  varies; the only reliable success signal is a decodable file. A genuine
  *launch* failure surfaces as a non-`shellFailed` error and is escalated to a
  failure toast. A non-zero exit with no file is indistinguishable from a
  cancel and is therefore treated as one.
- Always deletes the temp file before returning (`defer`).

`OCRError` is a small `enum OCRError: Error { case imageDecodeFailed }`
defined alongside `RegionCapture`.

### `OCRProvider`

`actor` conforming to `ActionProvider`. Orchestrates and absorbs all errors.

```
actor OCRProvider: ActionProvider {
    let itemKey: BuiltinItem = .ocr
    var permission: PermissionStatus { .notRequired }
    func run() async
}
```

`run()` sequence (the whole body is wrapped in `do` / `catch`):

1. `let image = try await RegionCapture.captureRegion()`
   - `RegionCapture` returns `nil` only for cancellation → return silently.
   - A thrown error (e.g. image decode failure) is caught by the outer
     `catch` → failure toast "识别失败".
2. `let lines = try await TextRecognizer.recognize(image)`
   - a thrown error is caught by the outer `catch` → failure toast "识别失败".
3. `lines.isEmpty` → failure toast "未识别到文字", return (clipboard untouched).
4. Join `lines` with `\n`, write to `NSPasteboard.general` (clear then set
   `.string`), then success toast "已复制到剪贴板".

Cancellation must be distinguishable from failure: `RegionCapture` signals
cancellation with a `nil` return value and signals every real fault by
throwing, so the `nil` check and the `catch` block never overlap.

`run()` catches every error internally and maps it to a toast; it never
propagates an error out. The clipboard write and every `ToastPresenter` call
hop to `@MainActor` via `await`.

> `ActionProvider.run()` is currently `func run() async throws`. `OCRProvider`
> implements it without ever throwing (a non-throwing body satisfies a
> `throws` requirement). No protocol change needed.

`OCRProvider` does **not** rely on actor isolation to prevent overlapping
runs. An `actor` releases its executor at every `await`, so a second
`run()` could interleave at the `RegionCapture` await and spawn a second
`screencapture` selection, racing two OCR pipelines and clobbering the
clipboard out of order. Overlap is prevented one level up, in
`PanelStore.run` — see Action In-Flight Guard.

### Action In-Flight Guard

`PanelStore.toggle(_:)` already drops overlapping calls via a
`togglesInFlight: Set<BuiltinItem>` guard. `PanelStore.run(_:)` has no
equivalent, so every hotkey press / row tap spawns a fresh
`Task { await run(item) }` with nothing to serialize them.

Add a symmetric guard:

```
private var actionsInFlight: Set<BuiltinItem> = []

func run(_ item: BuiltinItem) async {
    guard let provider = providers[item] as? any ActionProvider else { return }
    guard !actionsInFlight.contains(item) else { return }
    actionsInFlight.insert(item)
    defer { actionsInFlight.remove(item) }
    do { try await provider.run() }
    catch { logger.error("Run \(item.rawValue) failed: \(error)") }
}
```

`run` is `@MainActor`; the `contains` check and `insert` execute
synchronously before the first `await`, so a second `Task` entering `run`
for the same item observes the guard and returns. This protects OCR and,
as a side effect, hardens every other action against double-triggering.

### `ToastPresenter`

`@MainActor` `final class`, singleton (`ToastPresenter.shared`). Sole owner of
the toast window.

```
enum ToastStyle: Sendable {
    case success(String)
    case failure(String)
}

@MainActor
final class ToastPresenter {
    static let shared: ToastPresenter
    func show(_ style: ToastStyle)
}
```

Window:

- `NSPanel`, style mask `[.borderless, .nonactivatingPanel]`.
- `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`.
- `ignoresMouseEvents = true` (click-through, non-interactive).
- `canBecomeKey = false`, `canBecomeMain = false` (never steals focus).
- `level = .statusBar`.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
  so it appears above full-screen apps and on every Space.
- Content hosted by an `NSHostingController<ToastView>`; the panel is sized to
  the view's `fittingSize` on each `show`.

Positioning:

- Target screen = the `NSScreen` whose `frame` contains `NSEvent.mouseLocation`,
  falling back to `NSScreen.main`.
- Horizontally centered on the screen's `visibleFrame`.
- Vertical origin ≈ `visibleFrame.minY + 120` (bottom-center, clear of the Dock).

Lifecycle:

- `show(_:)`: cancel any pending dismiss `Task`, update `ToastView` content,
  resize + reposition the panel, `orderFrontRegardless()` (no `makeKey`),
  animate `alphaValue` 0 → 1 over 0.15s.
- A single cancellable `Task` then sleeps 1.0s, animates `alphaValue` 1 → 0
  over 0.2s, and calls `orderOut(nil)`.
- Re-trigger while a toast is visible: the new `show` cancels the pending
  dismiss `Task`, swaps content, and restarts the timer — the new toast
  replaces the old one in place.

### `ToastView`

SwiftUI view driven by `ToastStyle`.

- `HStack` of an SF Symbol icon and a `Text` label.
- Success: `checkmark.circle.fill`; failure: `xmark.circle.fill`.
- Background: `.regularMaterial` in a `Capsule`, consistent with the macOS 26
  visual language; comfortable padding.
- Fixed, compact width driven by content; single line of text.

## Error Handling

All cases are handled inside `OCRProvider.run()`; nothing propagates out.

| Situation | Behavior |
|-----------|----------|
| Esc cancels selection (no temp file produced) | Silent — no toast |
| Control held during selection (capture goes to clipboard, no file) | Silent — no toast (treated as cancellation) |
| `screencapture` fails to launch (non-`shellFailed` error) | Failure toast "识别失败" |
| Temp file produced but undecodable (`OCRError.imageDecodeFailed`) | Failure toast "识别失败" |
| Vision engine throws | Failure toast "识别失败" |
| Recognition result empty | Failure toast "未识别到文字", clipboard untouched |
| Recognition succeeded | Write clipboard + success toast "已复制到剪贴板" |
| Re-trigger while OCR mid-flight | Dropped by `PanelStore.run` in-flight guard |

## Concurrency

- `OCRProvider` is an `actor`, off the main actor. `TextRecognizer.recognize`
  is `async` and operates on `Sendable` inputs (`CGImage`), so it runs fine in
  the actor context.
- `ToastPresenter` is `@MainActor`; calls from `OCRProvider` cross the
  boundary with `await`. `ToastStyle` is `Sendable`.
- The `NSPasteboard` write is performed on `@MainActor`.
- Actor isolation does **not** serialize OCR runs (an `actor` yields at every
  `await`). Overlap is prevented by the `PanelStore.run` in-flight guard —
  see Action In-Flight Guard.
- No CGEvent-tap interaction; the hotkey dispatch path (callback →
  `DispatchQueue.main.async` → `PanelStore.dispatch`) is unchanged. The OCR
  work happens well after the tap callback returns, so the ~1s tap budget is
  not at risk.

## Testing

- **`TextRecognizerTests`** (automated, Swift Testing): add a PNG fixture under
  `Tests/AnyDoorTests/Fixtures/` containing known Chinese + English text;
  load it as a `CGImage`; assert `recognize()` returns strings containing the
  expected substrings, in top-to-bottom order.
- **`BuiltinItem` coverage**: extend existing/colocated tests so the new
  `.ocr` case's `kind`, `title`, and `symbol` are asserted.
- **`PanelStore.run` in-flight guard** (automated, `PanelStoreTests`): a test
  provider whose `run()` suspends on a continuation; assert a second
  `run(.ocr)` issued while the first is suspended is dropped (the provider's
  `run()` body executes once).
- **`RegionCapture`, `ToastPresenter`, `OCRProvider`**: interactive /
  windowing units — verified manually via `swift run AnyDoor`, triggering the
  OCR action and the assigned hotkey, and confirming: clipboard contents,
  toast appearance/position/timing, a >5s selection is not killed, and a
  rapid double-trigger starts only one capture.

## Open Questions

None. All design decisions are captured above.
