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
- Recognize mixed Chinese + English automatically.
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
| Input source | Interactive region selection via `screencapture -i` |
| Capture mechanism | `screencapture -i <tempfile>` to a temp PNG, decoded to `CGImage`, temp file deleted afterward |
| Cancellation (Esc) | Silent no-op — no toast, clipboard untouched |
| OCR engine | Vision framework, modern Swift API `RecognizeTextRequest` |
| Recognition languages | Automatic, `["zh-Hans", "en-US"]`; `.accurate` recognition level |
| Multi-line handling | One string per recognized observation, joined top-to-bottom with `\n` |
| Empty result | Failure toast "未识别到文字"; clipboard untouched |
| Toast content | Status only (icon + text); no recognized-text preview |
| Toast position | Bottom-center of the screen containing the mouse cursor |
| Toast lifetime | Fade-in 0.15s → hold 1.0s → fade-out 0.2s |
| Re-trigger | New toast replaces the current one (cancel pending dismiss, reset timer) |
| Permission | `OCRProvider.permission = .notRequired` |
| Menu integration | New `BuiltinItem.ocr` with `kind = .action` |

## Architecture

Five new units plus small edits to three existing files. Each new unit has a
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
  - `defaultOrder = 950` (just after `.screenshot` at 900)
  - `requiresAutomation = false`
  - `feedbackSound = nil`
- `AppDelegate.swift` — register `OCRProvider()` in the `providers` array.
- `BuiltinPreferenceSeeder` — no code change required; it iterates
  `BuiltinItem.allCases`, so the new case is seeded automatically.

## Component Details

### `TextRecognizer`

Pure, UI-free, shell-free. The only unit with an automated test.

```
enum TextRecognizer {
    static func recognize(_ image: CGImage) async throws -> [String]
}
```

- Uses Vision's modern Swift API `RecognizeTextRequest`.
- `recognitionLevel = .accurate`.
- Recognition languages fixed to `["zh-Hans", "en-US"]`.
- Returns the top candidate string of each observation, ordered
  top-to-bottom (sorted by observation bounding-box origin Y, descending in
  Vision's normalized coordinate space).
- Throws on a Vision engine error. An empty result is `[]`, not an error.

> Note: the exact `RecognizeTextRequest` API surface (property names,
> `perform(on:)` signature, observation accessor) is verified against the
> current macOS 26 SDK during implementation; the contract above is the
> stable part.

### `RegionCapture`

Wraps the native selection tool. Owns the temp-file lifecycle.

```
enum RegionCapture {
    /// Returns nil when the user cancels the selection.
    static func captureRegion() async throws -> CGImage?
}
```

- Builds a unique temp path under `FileManager.default.temporaryDirectory`.
- Runs `/usr/sbin/screencapture` with `["-i", <tempPath>]` via `ShellRunner`.
- Cancellation detection: if `ShellRunner` throws `BuiltinError.shellFailed`,
  **or** the temp file does not exist after the command returns, treat it as
  cancellation and return `nil`.
- If the temp file exists but cannot be decoded to a `CGImage`, throw an
  error (surfaces as a failure toast).
- Always deletes the temp file before returning (`defer`).

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
| Esc cancels selection (shell non-zero **or** temp file absent) | Silent — no toast |
| Capture succeeded but image decode failed | Failure toast "识别失败" |
| Vision engine throws | Failure toast "识别失败" |
| Recognition result empty | Failure toast "未识别到文字", clipboard untouched |
| Recognition succeeded | Write clipboard + success toast "已复制到剪贴板" |

## Concurrency

- `OCRProvider` is an `actor`, off the main actor. `TextRecognizer.recognize`
  is `async` and operates on `Sendable` inputs (`CGImage`), so it runs fine in
  the actor context.
- `ToastPresenter` is `@MainActor`; calls from `OCRProvider` cross the
  boundary with `await`. `ToastStyle` is `Sendable`.
- The `NSPasteboard` write is performed on `@MainActor`.
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
- **`RegionCapture`, `ToastPresenter`, `OCRProvider`**: interactive /
  windowing units — verified manually via `swift run AnyDoor`, triggering the
  OCR action and the assigned hotkey, and confirming clipboard contents and
  toast appearance/position/timing.

## Open Questions

None. All design decisions are captured above.
