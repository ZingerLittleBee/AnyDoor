# Screenshot Capture Engine + Quick Access Overlay (Phase 0)

**Date:** 2026-06-14
**Status:** Approved design — ready for implementation planning
**Scope:** Phase 0 of a larger screenshot/recording suite for AnyDoor

## Background

AnyDoor currently ships a minimal screenshot action: a single `.screenshot`
builtin that shells out to `screencapture -i -c` (region select → clipboard) and
records the result to clipboard history. Adjacent capabilities already exist and
are reused as-is: OCR (`TextRecognizer`), QR (`BarcodeRecognizer`), color picking
(`ColorSampler`), the screenshot preview panel, `ScreenCapturePermission`, and the
clipboard history / thumbnail stack.

The goal is a full-featured capture suite comparable to the leading paid macOS
screenshot tool. That suite is too large for one spec, so it is decomposed into
independent sub-projects, each with its own spec → plan → implementation cycle:

- **Phase 0 (this spec):** unified capture engine + quick access overlay
- Phase 1: annotation editor (arrows / shapes / text / blur-pixelate / crop / counter…)
- Phase 2: screen recording (MP4/GIF + mic / system audio / camera / keystrokes)
- Phase 3: scrolling capture (auto-scroll + lossless stitching)
- Later / nice-to-have: cloud upload + short links / team features

Phase 0 is the spine: window/timer capture and every "what happens after capture"
flow hang off it.

## Goals (Phase 0)

- Four capture kinds: **region**, **window**, **fullscreen**, **timer (delayed)**.
- Two entry models, both present: **discrete per-mode hotkeys** for power users,
  **plus** an **All-In-One mode bar** (one hotkey pops a floating toolbar) as the
  unified entry / discoverability fallback.
- A **custom selection overlay** (we own the selection UI) so we know the selected
  rectangle — required because the overlay follows the captured region, and because
  it unlocks crosshair, live dimensions, magnifier loupe, arrow-key nudge, and
  last-selection reuse. Pixels are grabbed via **ScreenCaptureKit**.
- A **Quick Access Overlay** that appears **next to the captured region** (fallback:
  bottom-right of the target display for fullscreen/window). All actions are fully
  implemented: **copy, save, edit-entry, pin, OCR, drag, re-capture, delete**.
- **Pin to screen** floating window (pulled into Phase 0): always-on-top, draggable,
  adjustable opacity, click-through toggle, close.
- Default post-capture behavior: **auto-save to a default directory** **and**
  **auto-copy to clipboard** **and** record to clipboard history; the overlay offers
  further actions (copy / rename / delete / …).

## Non-Goals (deferred)

- Annotation editor internals — Phase 0 only wires the **edit button** to open a
  **placeholder editor window**; real tools land in Phase 1.
- Screen recording (Phase 2), scrolling capture (Phase 3), cloud upload / sharing.
- Freeze-screen capture of transient UI — optional extra, not in Phase 0.
- OCR / QR / color picking are **not** rerouted through the new pipeline. They keep
  their current "result → clipboard" path; image captures go through the new overlay.
  OCR is additionally exposed as a **button on the overlay** (reusing `TextRecognizer`).

## Architecture

### New components

```
Sources/AnyDoor/Services/Capture/
  CaptureKind.swift           # value types: kind, timer delay, target (display / window / rect)
  ScreenCaptureService.swift  # actor: SCScreenshotManager stills (macOS 14+)
  CaptureCoordinator.swift    # @MainActor orchestrator: mode → selection → grab → output → overlay
  CaptureSettings.swift       # UserDefaults-backed config (dir / naming / auto-copy / auto-save / overlay timeout)
Sources/AnyDoor/Views/Capture/
  SelectionOverlayWindow.swift  # full-screen dimming selector: crosshair + dimension readout + magnifier
                                #   loupe + arrow-key nudge + Esc cancel + last-selection memory;
                                #   window mode highlights the hovered window and picks on click
  CaptureModeBarWindow.swift    # All-In-One floating mode bar (recording / scrolling shown disabled)
  CaptureOverlayWindow.swift    # quick access overlay (thumbnail = NSItemProvider drag source + action buttons)
  PinnedImageWindow.swift       # pin: always-on-top / drag / opacity / click-through / close
  AnnotationEditorWindow.swift  # placeholder editor window (filled in Phase 1)
Sources/AnyDoor/Services/Providers/
  CaptureProviders.swift        # region / window / fullscreen / timer / modeBar — five ActionProviders
```

### Component responsibilities & interfaces

- **`CaptureKind`** — pure value types (`Sendable`): the capture mode, optional
  timer delay (seconds), and the resolved target (a display, a window, or a rect).
  No behavior; trivially testable.

- **`ScreenCaptureService`** (`actor`) — wraps `SCShareableContent` discovery and
  `SCScreenshotManager.captureImage(contentFilter:configuration:)` to grab pixels
  for a given rect / display / window. Serializes capture calls. Returns a
  `CGImage`/`NSImage`. Window captures request the window's content filter (shadow
  is applied at composition time). Input: a resolved `CaptureKind` target. Output:
  an image or a typed error. No UI, no persistence.

- **`SelectionOverlayWindow`** (`@MainActor`, borderless non-activating `NSPanel`
  spanning all screens) — owns the selection interaction and reports the chosen
  `rect` + target display, or window-under-cursor in window mode, or cancellation.
  Provides crosshair, live W×H readout, magnifier loupe, arrow-key nudge, Esc to
  cancel, and remembers the last rect for reuse. Pure geometry helpers (rect
  normalization, clamping to display, dimension formatting, multi-display hit-test)
  are factored out for unit testing.

- **`CaptureModeBarWindow`** (`@MainActor` `NSPanel`) — the All-In-One bar. Renders
  mode buttons (region / window / fullscreen / timer enabled; recording / scrolling
  disabled placeholders). Selecting a mode calls back into `CaptureCoordinator`. The
  selection policy (which mode a key/click maps to) is a pure, testable function.

- **`CaptureOverlayWindow`** (`@MainActor`, non-activating `NSPanel`) — the quick
  access overlay. Positioned next to the captured region (fallback: target display
  bottom-right) via a pure positioning+edge-avoidance function. Shows the thumbnail
  (drag source via `NSItemProvider`) and action buttons: copy, save, edit (opens the
  placeholder editor), pin, OCR, re-capture (reuse last selection), delete. Auto-
  dismisses after a configurable timeout unless hovered/interacted.

- **`PinnedImageWindow`** (`@MainActor`, always-on-top `NSPanel`) — floating image
  reference: drag to move, opacity slider, click-through toggle, close.

- **`AnnotationEditorWindow`** (`@MainActor`, real window) — Phase 0 placeholder
  that shows the image with a "标注工具开发中" message. Real tools in Phase 1. As a
  real window it must set `isRestorable = false` and trigger `.regular` activation
  policy while open (via `RegularWindowCoordinator`).

- **`CaptureCoordinator`** (`@MainActor`) — the orchestrator. For each trigger:
  resolve mode → (run selection UI / countdown / pick window / grab fullscreen) →
  call `ScreenCaptureService` → apply output policy (auto-save + auto-copy + history)
  → present the overlay. Holds last-selection memory. Single entry point the
  providers call.

- **`CaptureSettings`** — UserDefaults-backed config, portable via
  `SyncSettingsRegistry`:
  - default save directory (default `~/Pictures/AnyDoor`)
  - filename template (default `Screenshot YYYY-MM-DD at HH.mm.ss`)
  - auto-copy on capture (default on)
  - auto-save on capture (default on)
  - overlay auto-dismiss timeout (default 8s)
  - timer delay presets (3 / 5 / 10s, default 5s)
  - mode-bar hotkey + per-mode hotkeys (stored via existing hotkey system)

### Data flow

```
trigger (hotkey / mode bar / command palette)
  → CaptureCoordinator
    → resolve kind
      → region:     SelectionOverlayWindow (rect)
      → window:     SelectionOverlayWindow (hovered window pick)
      → fullscreen: target display directly
      → timer:      on-screen countdown, then one of the above / fullscreen
    → ScreenCaptureService.capture(target) → image
    → output policy: auto-save to default dir (templated name)
                   + auto-copy to clipboard
                   + ClipboardHistoryStore (kind .screenshot)
    → CaptureOverlayWindow next to region (fallback bottom-right)
      → user action: copy / save / edit (placeholder) / pin / OCR / drag / re-capture / delete
```

### Integration with existing systems

- **BuiltinItem** (`Models/BuiltinItem.swift`): repurpose `.screenshot` as **region
  capture**; add `.captureWindow`, `.captureFullscreen`, `.captureTimer`,
  `.captureModeBar`. Each gets titleKey / SF Symbol / defaultOrder / historyKind.
- **Providers** (`AppDelegate` registration): append the five new `ActionProvider`s;
  all route into `CaptureCoordinator`.
- **Hotkeys**: reuse `HotkeyAction.runBuiltin(itemKey:)`; each mode bindable
  individually, plus one mode-bar hotkey. No change to `HotkeyService` internals or
  the `HotkeySnapshot` concurrency model.
- **Command palette**: one entry per mode; timer exposes a second-level menu to pick
  the delay (3 / 5 / 10s) via the existing `CommandPaletteOptions` option-parent
  mechanism.
- **Permission**: reuse `ScreenCapturePermission`; gate the first capture and surface
  a Toast that deep-links to Settings when denied.
- **History**: reuse `ClipboardHistoryStore` (`.screenshot` kind) and
  `ClipboardThumbnail` for the overlay thumbnail.
- **Window policy**: selection overlay / mode bar / quick-access overlay / pin are
  non-activating `NSPanel`s (same pattern as `ShutdownWarningWindowController`), so
  they do not need `.regular`. The placeholder editor is a real window → `.regular`
  while open + `isRestorable = false` (verify it is never state-restored).
- **Config sync**: capture settings join `SyncSettingsRegistry` (machine-portable);
  the save directory is portable as a path string.

## Error handling

- **Permission denied** → Toast with a "open Settings" deep link; abort cleanly, no
  crash.
- **Selection cancelled (Esc)** → no capture, no save, no overlay; silent.
- **Capture failure** (ScreenCaptureKit error) → Toast `.failure`; nothing written.
- **Save failure** (disk / permissions) → Toast `.failure`; the image still lands in
  clipboard + history so work is not lost.
- **Multi-display / display disconnect mid-selection** → selection clamps to the
  active display; stale targets resolve to the main display.

## Concurrency (Swift 6 strict)

- Selection overlay, mode bar, quick-access overlay, pin window, coordinator are all
  `@MainActor`.
- `ScreenCaptureService` is an `actor` serializing capture I/O.
- Capture results cross actor boundaries as `Sendable` value types (`CaptureKind`,
  image wrapped appropriately).
- No change to the CGEvent tap / `HotkeySnapshot` path.

## Testing

Pure logic unit tests (no UI):

- Selection rect math: normalization, clamping to display bounds, multi-display
  hit-testing, dimension formatting.
- Filename templating (date tokens → string; collision suffixing).
- Last-selection memory (store/recall, reuse on re-capture).
- Overlay positioning + edge avoidance (region near each screen edge → on-screen,
  non-overlapping placement; fullscreen/window fallback to bottom-right).
- Mode-bar selection policy (key/click → mode mapping).
- Timer delay parsing / preset selection.

Manual verification: ScreenCaptureKit grabs, Vision OCR button, drag-and-drop to
other apps, pin window opacity / click-through, permission gating, multi-display.

## Open defaults (committed unless changed during review)

- Default save dir: `~/Pictures/AnyDoor`
- Filename template: `Screenshot YYYY-MM-DD at HH.mm.ss`
- Timer presets: 3 / 5 / 10s (default 5s)
- Magnifier loupe: included in the selection overlay
- Overlay auto-dismiss: 8s unless hovered/interacted
