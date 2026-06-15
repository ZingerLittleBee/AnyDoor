# Scrolling Capture (Phase 3) Design

**Goal:** Capture content taller than the screen by auto-scrolling a selected
region and losslessly stitching the frames into one tall image.

**Status:** design

## Summary

The user selects a rectangular viewport over a scrollable area. AnyDoor then
repeatedly: posts a scroll-wheel event over the viewport, waits for the content
to settle, grabs the viewport, and stitches the newly revealed rows onto a
growing bitmap. It stops when scrolling no longer reveals new content (bottom
reached) or a safety cap is hit. The result flows through the same output policy
as a normal capture (auto-save / auto-copy / quick-access overlay / edit / pin /
history).

This is **region-based** scrolling capture (the most reliable, content-agnostic
approach). Window-aware scrolling is out of scope for v1.

## Why this approach

- **Universal:** image-space scroll-and-stitch works on any scrollable UI
  (browsers, editors, lists) without needing the app to expose its content via
  Accessibility.
- **Crash-safe:** uses synchronous CoreGraphics (`LegacyScreenCapture`), never
  ScreenCaptureKit — same reason as the rest of the capture suite (the macOS 26
  executor-corruption bug). The loop runs on the main actor with `Task.sleep`
  only (no cross-isolation `await`), like `CaptureCoordinator`.
- **Lossless:** all work is on raw pixels; the stitched bitmap is encoded to PNG
  exactly once at the end.

## Components

### `ScrollStitch` (pure, fully unit-tested)

The testable core. Operates on per-row fingerprints, not pixels.

```swift
enum ScrollStitch {
    typealias RowSig = UInt64

    struct OverlapResult: Equatable {
        let delta: Int        // rows of NEW content revealed at the bottom of `cur`
        let matchRatio: Double
        let overlap: Int      // overlapping rows = H - delta
    }

    /// How far `cur` scrolled past `prev`. Both are top-to-bottom row
    /// fingerprints of equal length H. Returns the count of new bottom rows
    /// (`delta`), the match ratio, and the overlap; nil if no alignment meets
    /// `minMatchRatio`. `expected` (rows) breaks ties when the overlap is
    /// ambiguous (uniform bands).
    static func detectOverlap(prev: [RowSig], cur: [RowSig],
                              minOverlap: Int, minMatchRatio: Double,
                              expected: Int?) -> OverlapResult?
}
```

Algorithm: for each candidate shift `d` in `0 ... (H - minOverlap)`, compare
`cur[0 ..< H-d]` against `prev[d ..< H]`, count matching row signatures, and
keep the best by `(ratio desc, |d - expected| asc, d desc)`. `d` equals `delta`
(content shifted up by `d` rows ⇒ the bottom `d` rows of `cur` are new). `delta
== 0` ⇒ no scroll happened ⇒ bottom reached.

Degenerate guard: if every row of `prev` is identical (fully uniform), return
`nil` (no reliable anchor).

### `ScrollCapturePolicy` (pure value type)

Tunable constants with sane defaults: `scrollLines` (wheel lines per step),
`settleMillis`, `maxFrames`, `maxTotalHeightFactor` (cap stitched height =
viewportH × factor), `minOverlapRatio`, `minMatchRatio`, `stableStopCount`
(consecutive no-progress frames before stopping). Includes a pure
`shouldStop(frameIndex:delta:totalHeight:viewportHeight:noProgressStreak:)`
decision helper so the stop logic is testable.

### `ScrollCaptureEngine` (`@MainActor`)

Drives the loop with real pixels:

1. Resolve the display containing the viewport; convert the viewport's global
   AppKit rect to a pixel crop rect (reusing the overlay's conversion math).
2. Grab frame 0 (crop a fresh `LegacyScreenCapture.display` to the viewport),
   seed the accumulator bitmap + `prev` row signatures.
3. Loop on the main actor (`Task { @MainActor }` + `Task.sleep`):
   - warp the cursor to the viewport center, post a scroll-down `CGEvent`
     (`scrollWheelEvent2Source`, negative `wheel1`);
   - sleep `settleMillis`;
   - grab + crop the viewport → `cur`; compute `cur` signatures;
   - `detectOverlap(prev, cur, …)`;
   - stop per `ScrollCapturePolicy.shouldStop`; otherwise composite `cur`'s
     bottom `delta` pixel rows onto the growing bitmap and advance `prev = cur`.
4. Build a `CGImage` from the accumulator and return it.

Row signatures are computed from each pixel row's bytes (a fast 64-bit hash);
exact integer scrolling preserves pixels, so identical rows hash identically.

### `ScrollCaptureCoordinator` (`@MainActor`)

Mirrors `RecordingCoordinator`. Entry points: region selection via
`SelectionOverlayWindow` (region mode) → `ScrollCaptureEngine.capture(...)` →
hand the tall image to `CaptureCoordinator` for the shared output policy. Guards
re-entrancy with an in-flight flag; restores the cursor position after.

## Wiring

- New builtin `captureScrolling` (action; icon `arrow.down.to.line`; order 930)
  + `CaptureScrollingProvider`, registered in `AppDelegate`.
- The All-In-One mode bar's scrolling button is enabled (`onScroll`), starting a
  scrolling capture.
- `CaptureCoordinator` exposes an internal `deliverCapturedImage(_:anchor:)`
  wrapping its existing private `present(image:anchor:)` so the scroll
  coordinator reuses save/copy/overlay/edit/pin/history unchanged.
- Localized strings (en + zh-Hans) for the builtin and a "stitched N screens"
  success toast.

## Permissions & coordinate notes

- Posting scroll events + warping the cursor needs Accessibility (already held
  for the global hotkey tap). Screen capture needs Screen Recording (already
  required by the suite).
- Cursor warp uses CG global coordinates (top-left origin); the viewport rect is
  AppKit global (bottom-left). Convert via the primary display height.

## Testing

- `ScrollStitcherTests`: exact overlap, partial-mismatch tolerance, no-overlap →
  nil, uniform-band tie-break via `expected`, fully-uniform → nil, `delta == 0`
  bottom detection, `minOverlap` enforcement.
- `ScrollCapturePolicyTests`: `shouldStop` on no-progress streak, height cap,
  and frame cap.

Engine/coordinator are thin glue over the tested core + the already-proven
`LegacyScreenCapture`; they are verified at runtime, not unit-tested (they need
real displays and event posting).

## Out of scope (v1)

Horizontal scrolling, window-aware auto-detection of the scroll area, scroll
inside nested/overlay scrollers, and capturing fixed headers/footers only once.
