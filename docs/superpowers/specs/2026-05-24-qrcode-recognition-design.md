# QR Code Recognition — Design

**Date**: 2026-05-24
**Status**: Approved (design phase)
**Author**: Brainstorming session

## Summary

Add a QR-code recognition action to the AnyDoor panel. When triggered, the
user drags a selection rectangle over any part of the screen (the native
macOS region selection UI). Every QR code found in the selected region is
decoded via the built-in Vision barcode detector, the resulting payload
strings are written to the system clipboard (newline-joined when there are
multiple), and a transient toast at the bottom-center of the screen reports
success or failure. The toast auto-dismisses after ~1 second and **never
displays the decoded payload itself** — status only.

The feature reuses the existing `BuiltinItem` / `ActionProvider`
infrastructure, so the QR entry can be reordered, hidden, and assigned a
global hotkey from the panel settings, exactly like "屏幕取词".

Architecturally this is the QR-code twin of [OCR Screen Text](2026-05-22-ocr-screen-text-design.md):
same capture pipeline, parallel recognizer, identical clipboard + toast
contract. All shared infrastructure (`RegionCapture`, `ToastPresenter`,
`PanelStore.run` in-flight guard, `ShellRunner` optional timeout) already
exists from the OCR implementation and is reused unchanged.

## Goals

- Trigger via the panel row or an assignable global hotkey.
- Capture an arbitrary screen region using the native macOS selection UI
  (`RegionCapture`, reused).
- Decode QR codes with the macOS Vision framework (no third-party engine),
  restricted to QR symbology only.
- Write the decoded payload(s) to `NSPasteboard.general` as plain text,
  regardless of payload content (URL, Wi-Fi config, vCard, plain text, …).
- Show a non-interactive toast at the bottom-center of the screen reporting
  success or failure, auto-dismissing after ~1 second. The toast text is
  status only; the decoded payload is never shown in the toast.

## Non-Goals

- No automatic action on payload content (no "open URL", no Wi-Fi join, no
  vCard import). The clipboard is the sole sink in this iteration.
- No payload preview UI of any kind.
- No support for other barcode symbologies (EAN, Code 128, Aztec, …); the
  detector is explicitly limited to `.qr`.
- No full-screen scan and no decoding of a pre-existing clipboard image;
  region selection is the only input source.
- No custom selection overlay (ScreenCaptureKit); the native `screencapture`
  tool is reused via `RegionCapture`.
- No payload sanitization, deduplication beyond what the detector returns,
  or transformation (e.g. URL-decoding) — payloads are written verbatim.
- No default global hotkey; users assign one in panel settings if they want.
- No history of past decodings.

## Clarifications Captured

| Topic | Decision |
|-------|----------|
| Input source | Interactive region selection via `RegionCapture` (existing) |
| Detection engine | Vision `VNDetectBarcodesRequest`, classic Objective-C-bridged API (mirrors `TextRecognizer`'s use of `VNRecognizeTextRequest`) |
| Symbology filter | `request.symbologies = [.qr]` — QR codes only |
| Result handling | Always copy to clipboard; never branch on payload content |
| Multi-code handling | Join all non-empty `payloadStringValue`s with `\n`, ordered top-to-bottom by `boundingBox.maxY` (parallel to `TextRecognizer`'s line ordering) |
| Empty result | Failure toast "未识别到二维码"; clipboard untouched |
| Failure | Failure toast "识别失败"; clipboard untouched |
| Success toast | "已复制到剪贴板" — **no decoded content shown** |
| Toast presenter | Reuse existing `ToastPresenter.shared` and `ToastStyle` |
| Cancellation | Reuse `RegionCapture`'s `nil`-return cancel semantics — silent, no toast |
| Permission | `QRCodeProvider.permission = .notRequired` |
| Menu integration | New `BuiltinItem.qrcode` with `kind = .action` |
| Default hotkey | None — users assign one in panel settings if desired |
| Panel ordering | `defaultOrder = 960`, positioning the row between OCR (950) and 取色 (975) on fresh installs only. Existing installs receive the row appended at the end of the panel (the seeder's standing contract); the user can reorder it in panel settings. No migration |
| Re-trigger | Dropped by the existing `PanelStore.run` per-item in-flight guard |
| `BuiltinPreferenceSeeder` | No code change required; iterates `BuiltinItem.allCases` |

## Architecture

One new recognizer + one new provider, plus a single `BuiltinItem` case and
its registration. Everything else is reused.

```
                 hotkey / panel row
                        │
                        ▼
        ┌───────────────────────────────┐
        │  QRCodeProvider (actor)       │   ActionProvider
        │  run():                       │
        │   1. RegionCapture.capture()  │──► CGImage? (nil = cancelled)
        │   2. BarcodeRecognizer.scan() │──► [String]
        │   3. NSPasteboard write       │
        │   4. ToastPresenter.show()    │
        └───────────────────────────────┘
                        │ await (MainActor hop)
                        ▼
        ┌───────────────────────────────┐
        │  ToastPresenter.shared        │  (existing — unchanged)
        └───────────────────────────────┘
```

### New files

```
Sources/AnyDoor/
└── Services/
    ├── BarcodeRecognizer.swift          # Vision wrapper, pure, testable
    └── Providers/
        └── QRCodeProvider.swift         # ActionProvider orchestrating the flow
```

### Modified files

- `Models/BuiltinItem.swift` — add `case qrcode`:
  - `kind = .action`
  - `title = "识别二维码"`
  - `symbol = "qrcode.viewfinder"`
  - `defaultOrder = 960`
  - `requiresAutomation = false`
  - `feedbackSound = nil`
- `AppDelegate.swift` — register `QRCodeProvider()` in the `providers` array
  (the exact registration site mirrors how `OCRProvider()` is registered).

No other files change. In particular:

- `RegionCapture.swift` is reused as-is. It is already named generically (not
  OCR-specific); `OCRError.imageDecodeFailed` remains the error case that
  surfaces from a corrupt capture and is still treated as a failure toast by
  `QRCodeProvider`. (Renaming `OCRError` is out of scope — leave it for a
  later cleanup that consolidates capture errors.)
- `ToastPresenter`, `ToastView`, and `ToastStyle` are reused unchanged.
- `PanelStore.run`'s per-item in-flight guard already covers every
  `ActionProvider` and therefore covers `QRCodeProvider` automatically.
- `ShellRunner.run`'s optional timeout is already in place from the OCR work.
- `BuiltinPreferenceSeeder` iterates `BuiltinItem.allCases` and seeds the new
  case with no code change.

### Panel Ordering (existing vs fresh installs)

`BuiltinPreferenceSeeder` only applies `defaultOrder` on a **fresh install**
(`existing.isEmpty`). For an install that already has `BuiltinPreference`
rows, the seeder appends every new `BuiltinItem` at the end of the panel
(`maxOrder + 100`, incrementing). Therefore:

- **Fresh install** — 识别二维码 appears between 屏幕取词 and 屏幕取色.
- **Existing install** — 识别二维码 appears at the bottom of the panel; the
  user can drag it anywhere in panel settings.

This matches every previously-added built-in and keeps the seeder's
documented contract intact. No migration. `defaultOrder = 960` is still
defined because it governs the fresh-install seeding order (every
`BuiltinItem` case must supply one). `MigrationTests` continues to assert
the append-at-end behavior for existing installs.

## Component Details

### `BarcodeRecognizer`

Pure, UI-free, shell-free — fixture-backed automated test (see Testing).

```
enum BarcodeRecognizer {
    /// Decodes all QR codes in `image`. Returns one string per code,
    /// ordered top-to-bottom. An empty array means no QR code was found
    /// (not an error).
    static func scan(_ image: CGImage) async throws -> [String]
}
```

- Wraps `VNDetectBarcodesRequest` in a `withCheckedThrowingContinuation`
  dispatched onto `DispatchQueue.global(qos: .userInitiated)` — parallel in
  structure to `TextRecognizer.recognize`.
- `request.symbologies = [.qr]` so the detector ignores every other barcode
  type.
- `VNImageRequestHandler(cgImage: image, options: [:])`, then
  `try handler.perform([request])`.
- Reads `request.results` (an `[VNBarcodeObservation]?`), filters out
  observations with a `nil` or empty `payloadStringValue`, and orders the
  remainder top-to-bottom by `boundingBox.maxY` (descending — Vision's
  normalized coordinate space has Y increasing upward). This matches
  `TextRecognizer`'s ordering convention so multi-code joins are spatially
  predictable.
- An empty result is `[]`, not an error. Engine errors propagate via
  `continuation.resume(throwing:)`.

### `QRCodeProvider`

`actor` conforming to `ActionProvider`. Orchestrates and absorbs all errors —
parallel in structure to `OCRProvider`.

```
actor QRCodeProvider: ActionProvider {
    let itemKey: BuiltinItem = .qrcode
    var permission: PermissionStatus { .notRequired }
    func run() async
}
```

`run()` sequence (whole body wrapped in `do` / `catch`):

1. `let image = try await RegionCapture.captureRegion()`
   - `nil` → user cancelled → return silently (no toast, clipboard untouched).
   - A thrown error (e.g. `OCRError.imageDecodeFailed`) is caught by the
     outer `catch` → failure toast "识别失败".
2. `let payloads = try await BarcodeRecognizer.scan(image)`
   - A thrown error is caught by the outer `catch` → failure toast "识别失败".
3. `payloads.isEmpty` → failure toast "未识别到二维码", return (clipboard
   untouched).
4. Join `payloads` with `\n`, hop to `@MainActor`, write to
   `NSPasteboard.general` (clear then set `.string`), then success toast
   "已复制到剪贴板" — payload content is **not** included in the toast.

Cancellation must be distinguishable from failure: `RegionCapture` signals
cancellation with a `nil` return and signals every real fault by throwing,
so the `nil` check and the `catch` block never overlap.

`run()` catches every error internally and maps it to a toast; it never
propagates an error out. The clipboard write and every `ToastPresenter` call
hop to `@MainActor` via `await`.

Per the OCR design's established pattern, `QRCodeProvider` does **not** rely
on actor isolation to prevent overlapping runs (an `actor` releases its
executor at every `await`). Overlap is prevented by the existing
`PanelStore.run` per-item in-flight guard.

## Error Handling

All cases are handled inside `QRCodeProvider.run()`; nothing propagates out.

| Situation | Behavior |
|-----------|----------|
| Esc cancels selection (no temp file produced) | Silent — no toast |
| Control held during selection (capture goes to clipboard, no file) | Silent — no toast (treated as cancellation) |
| `screencapture` fails to launch | Failure toast "识别失败" |
| Temp file produced but undecodable (`OCRError.imageDecodeFailed`) | Failure toast "识别失败" |
| Vision detector throws | Failure toast "识别失败" |
| Recognition result empty | Failure toast "未识别到二维码", clipboard untouched |
| Recognition succeeded (1+ codes) | Write `\n`-joined payloads to clipboard + success toast "已复制到剪贴板" |
| Re-trigger while mid-flight | Dropped by existing `PanelStore.run` in-flight guard |

## Concurrency

- `QRCodeProvider` is an `actor`, off the main actor. `BarcodeRecognizer.scan`
  is `async` and operates on `Sendable` inputs (`CGImage`), so it runs fine
  in the actor context.
- `ToastPresenter` is `@MainActor`; calls from `QRCodeProvider` cross the
  boundary with `await`. `ToastStyle` is `Sendable`.
- The `NSPasteboard` write is performed on `@MainActor`.
- Actor isolation does **not** serialize runs; overlap prevention lives in
  `PanelStore.run`'s existing in-flight guard.
- No CGEvent-tap interaction; the hotkey dispatch path is unchanged. The QR
  work happens well after the tap callback returns, so the ~1 s tap budget
  is not at risk.

## Testing

- **`BarcodeRecognizerTests`** (automated, Swift Testing): add a PNG fixture
  under `Tests/AnyDoorTests/Fixtures/` containing one QR code with a known
  payload (e.g. `"https://example.com/anydoor"`); load it as a `CGImage`;
  assert `scan()` returns exactly one string equal to that payload. A second
  fixture containing two QR codes asserts the top-to-bottom ordering.
- **`BuiltinItem` coverage**: extend existing/colocated tests so the new
  `.qrcode` case's `kind`, `title`, and `symbol` are asserted.
- **`PanelStore.run` in-flight guard**: already covered by the OCR test; no
  duplication needed.
- **`QRCodeProvider` (manual)**: verified manually via `swift run AnyDoor` —
  trigger via panel row and via an assigned hotkey, confirm:
  - clipboard contains the decoded payload (single code);
  - clipboard contains `\n`-joined payloads when the selection covers two
    codes;
  - empty selection produces the "未识别到二维码" toast and clipboard is
    untouched;
  - Esc cancellation is silent;
  - rapid double-trigger starts only one capture;
  - toast message text contains no payload content.

## Open Questions

None. All design decisions are captured above.
