# Interactive Scrolling Capture (CleanShot X style)

- Date: 2026-06-15
- Status: Approved (autonomous implementation authorized by the user)
- Area: `Sources/AnyDoor/Services/Capture/`, `Sources/AnyDoor/Views/Capture/`

## 1. Summary

Replace the unreliable **fully-automatic** scrolling capture (warp the cursor +
post synthetic scroll-wheel events + stitch, no user feedback) with a CleanShot
X-style **interactive session**: after the region is selected, a floating preview
panel appears with a **Done / Cancel** toolbar; the user **manually scrolls** the
target content; the app captures + stitches frames live as they scroll, growing
the preview; **Done** delivers the stitched long image through the standard
post-capture overlay (copy / save / edit / pin / OCR), **Cancel** discards.

## 2. Current state & why it fails

- `ScrollCaptureCoordinator.capture(region:)` → `ScrollCaptureEngine.capture(...)`,
  which warps the cursor to the viewport center, posts `CGEvent` scroll-wheel
  events, grabs the viewport via `LegacyScreenCapture.display` + crop, aligns
  consecutive frames with `ScrollStitch.detectOverlap` (row signatures), stitches,
  and stops by heuristic — then delivers via `CaptureCoordinator.deliverCapturedImage`.
- Fragility: synthetic scrolls often don't reach the target's scroll view (focus,
  natural-scroll sign, non-scrollable region), so the loop captures one viewport
  and "finishes" with no visible result the user can act on. There is **no preview
  and no user control**, which is the reported problem ("the window disappeared, I
  can't save").

## 3. Goals / Non-goals

### Goals
- Manual scroll drives capture; the app observes real `.scrollWheel` events.
- A floating **preview panel** shows the stitched-so-far image, auto-scrolled to
  the bottom, with a captured-height readout and a **Done / Cancel** toolbar.
- A thin **outline** marks the capture viewport so the user knows where to scroll.
- The app's own windows (preview, outline) **never appear in the stitched image**.
- **Done** → standard output policy (quick-access overlay). **Cancel** → discard.
- Reuse the proven pure stitching pieces (`ScrollStitch.detectOverlap`, row
  signatures, compositing).

### Non-goals
- Keeping the synthetic auto-scroll as a user-facing mode (removed as the default;
  the auto-loop code is deleted, its pure helpers retained).
- ScreenCaptureKit (constraint: `LegacyScreenCapture` synchronous CoreGraphics only).
- Cross-display capture viewports (per-display, as today).
- Annotation/quick-access overlay changes (reused unchanged).

## 4. Decisions (confirmed / autonomous)

| Topic | Decision |
| --- | --- |
| Driving | **Manual scroll + live preview** (user-confirmed). |
| Done destination | **Standard post-capture overlay** (user-confirmed). |
| Scope | Both the toolbar "滚动" button and the standalone "滚动截图" builtin use the session. |
| Exclude own UI from grab | Capture the viewport **below our session window** via `CGWindowListCreateImage(.optionOnScreenBelowWindow)` — no flicker, no placement constraints. |
| Outline | Lightweight border panel at the viewport, ordered **above** the preview panel so the "below preview" grab excludes it too. |
| Keyboard | Cancel on **Esc** (global monitor, observe-only); Done/Cancel primarily via buttons (panels are non-activating so the target keeps scroll focus). |

## 5. Architecture

```
ScrollCaptureCoordinator.capture(region:)        // entry (toolbar + builtin)
        │  start
        ▼
ScrollCaptureSession (@MainActor)                // interactive controller
  ├─ global .scrollWheel monitor (throttled ~60ms + trailing grab ~180ms)
  ├─ grab: LegacyScreenCapture.belowWindow(previewWindowID, bounds: viewportCG)
  ├─ ScrollStitchAccumulator.ingest(frame) -> appended?    // running stitch
  ├─ ScrollCaptureSessionWindow (preview + Done/Cancel + readout)
  └─ ScrollViewportOutlineWindow (thin border at the viewport)
        │  Done                              │ Cancel
        ▼                                    ▼
CaptureCoordinator.deliverCapturedImage      (discard)
```

Non-activating `.nonactivatingPanel`s (like `RecordingControlsWindow`) so the
target window keeps focus and the user can scroll it. SwiftUI buttons in a
non-activating panel receive clicks (validated by the capture toolbar in Phase 2).

## 6. Components

### 6.1 `LegacyScreenCapture.belowWindow(_:bounds:)` (new)
```swift
private static let kOptionOnScreenBelowWindow: UInt32 = 1 << 2
/// Everything on screen below `windowID`, clipped to `bounds` (CG global coords,
/// top-left origin). Used by scrolling capture to grab the viewport without the
/// session's own preview/outline windows in the shot.
static func belowWindow(_ windowID: CGWindowID, bounds: CGRect) -> CGImage?
```
Calls the dlsym'd `CGWindowListCreateImage(bounds, kOptionOnScreenBelowWindow, windowID, kImageBestResolution)`.

### 6.2 `ScrollCaptureEngine` → pure helpers only
Strip to `enum ScrollCaptureEngine` holding the existing `static` pixel helpers
(`rowSignatures`, `fnv1a`, `composite`). Remove the instance auto-loop
(`capture`, `scheduleStep`, `advance`, `postScroll`, `finish`, `grabViewport`,
all instance state). `ScrollCaptureEngineTests` only exercises the statics, so it
is unchanged.

### 6.3 `ScrollStitchAccumulator` (new, `@MainActor` value-ish controller)
Owns the running stitch state, factored out of the old loop so it is unit-testable:
```swift
final class ScrollStitchAccumulator {
    init(policy: ScrollCapturePolicy = ScrollCapturePolicy())
    private(set) var sliceCount: Int
    /// Total stitched height in pixels (0 until the first frame).
    var totalHeight: Int { get }
    /// Ingest a freshly grabbed viewport frame. The first frame seeds the stitch;
    /// later frames are aligned via ScrollStitch.detectOverlap and only the newly
    /// revealed rows are appended. Returns true when rows were appended (progress).
    @discardableResult func ingest(_ frame: CGImage) -> Bool
    /// The stitched image so far (nil before the first frame).
    func composite() -> CGImage?
}
```
Uses `ScrollCaptureEngine.rowSignatures` / `.composite` + `ScrollStitch.detectOverlap`,
mirroring the old `advance()` math (delta>0 appends `cur` cropped to its bottom
`delta` rows; tracks `prevSig` + `lastDelta`; seeds `viewportPx` + `minOverlap`
from the first frame). Both directions handled by `detectOverlap` (scroll down
reveals rows at the bottom; this is the supported direction, as today).

### 6.4 `ScrollCaptureSession` (new, `@MainActor`)
The controller. `start(viewport:display:)`:
1. Build + show `ScrollViewportOutlineWindow` (at the viewport) and
   `ScrollCaptureSessionWindow` (preview + toolbar), the outline ordered above the
   preview. Record the preview panel's `windowNumber` for the grab exclusion.
2. Grab the first frame immediately (`belowWindow`), `accumulator.ingest`, update
   the preview.
3. Install a global `.scrollWheel` monitor: on scroll, throttle grabs to ~60ms and
   schedule a trailing grab ~180ms after the last scroll; each grab → `ingest` →
   if appended, refresh the preview (composite) and the readout.
4. Install a global `.keyDown` monitor: Esc → cancel.
5. `done()` → tear down monitors + windows, final `composite()`, and
   `CaptureCoordinator.shared.deliverCapturedImage(image, anchor: viewport)`
   (toast failure + no-op if nil). `cancel()` → tear down, deliver nothing.
6. Re-entrancy guard (one session at a time); cleanup is idempotent.

Throttle/trailing timing uses normal AppKit timers (`Date`/`DispatchQueue` —
this is app code, not a workflow script). The only capture call is the synchronous
`LegacyScreenCapture.belowWindow`, so the executor-corruption constraint holds.

### 6.5 `ScrollCaptureSessionWindow` (new view, modeled on `RecordingControlsWindow`)
`@MainActor` class owning an `NSPanel` (`.borderless`, `.nonactivatingPanel`,
`.statusBar` level, `.canJoinAllSpaces`, `isMovableByWindowBackground`) hosting a
SwiftUI view bound to an `@Observable` model:
- A `ScrollView` preview of the composited `NSImage`, auto-scrolled to the bottom
  on each update (`ScrollViewReader`).
- A captured-height readout (`已捕获 N px`, localized).
- A bottom toolbar: `Cancel` (secondary) + `Done` (prominent). Localized strings.
Panel size ~ 320×420, placed at the viewport display's bottom-right (draggable).
Exposes `present(model:onDone:onCancel:)`, `updatePreview(NSImage, heightPx:)`,
`dismiss()`, and `windowNumber`.

### 6.6 `ScrollViewportOutlineWindow` (new, small)
A click-through (`ignoresMouseEvents = true`) borderless transparent `NSPanel` at
the viewport frame, drawing a 2px accent inset border. Ordered above the preview.
`present(frame:)` / `dismiss()`.

### 6.7 `ScrollCaptureCoordinator` (rework)
Drop the `ScrollCaptureEngine` instance + auto-loop usage. `capture(region:)` and
`capture()` resolve the viewport (region handoff, or its own selection overlay for
the `nil`/standalone path) then `ScrollCaptureSession.shared.start(viewport:display:)`.
Keep the permission gate and the `inFlight` guard; `finish()` is released when the
session ends (success or cancel) via a completion callback.

## 7. Coordinate spaces

- Viewport: global AppKit (bottom-left). For `belowWindow` bounds convert to CG
  global (top-left): `x = viewport.minX`, `y = primaryMaxY - viewport.maxY`,
  size unchanged, where `primaryMaxY = NSScreen.screens.first?.frame.maxY`
  (mirrors the old engine's `cgPoint(fromAppKit:)`).
- Grabbed frames are pixels at the display scale; the accumulator compares pixel
  rows, so consecutive grabs align without explicit scale handling.
- Delivered anchor = the viewport (global AppKit), as today.

## 8. Testing

- Unit (pure): `ScrollStitchAccumulator` — first frame seeds (height = frame
  height, 1 slice); a frame scrolled by N appends N rows (totalHeight grows by N);
  an identical frame appends nothing; `composite()` stacks top-to-bottom and is
  nil before the first frame. Reuses the synthetic-image helpers from
  `ScrollCaptureEngineTests`. Existing `ScrollStitcherTests` / `ScrollCaptureEngineTests`
  stay green.
- Manual: select region → 滚动 → scroll a long web page/document → preview grows →
  Done saves a tall image via the overlay; Cancel/Esc discards; outline marks the
  region; the preview/outline never appear in the stitched output; standalone
  "滚动截图" builtin behaves the same.

## 9. Risks

- **Grab excludes own UI** depends on z-order (content < preview < outline) and the
  `.optionOnScreenBelowWindow` semantics; validate the stitched image is clean
  early.
- **Fast scrolls** can jump more than a viewport (no overlap → frame dropped); the
  ~60ms throttle + trailing grab keeps frames overlapping for normal scrolling;
  a dropped frame just isn't appended (no corruption).
- **Preview cost**: re-compositing per appended frame is O(total height); fine for
  typical captures. If a capture gets very tall this can be optimized to an
  incremental running bitmap later.
- **Non-activating panels + button clicks** already validated by the Phase 2 toolbar.
</content>
