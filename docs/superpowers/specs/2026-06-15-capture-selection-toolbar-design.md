# Capture: Pre-shown Adjustable Selection + Attached Type Toolbar (CleanShot X style)

- Date: 2026-06-15
- Status: Approved (design); pending spec review
- Area: `Sources/AnyDoor/Services/Capture/`, `Sources/AnyDoor/Views/Capture/`

## 1. Summary

Replace the region screenshot "drag on an empty dimmed screen to create a
selection" interaction with a CleanShot X–style flow: triggering the screenshot
menu (and the unified All-In-One entry) **immediately shows an adjustable
selection rectangle** — restored from the last selection, or a default centered
rectangle — with a **toolbar attached directly below the selection** that lets
the user switch the capture type (region / window / fullscreen / scrolling /
recording) and execute it.

## 2. Current state

- Entry: `BuiltinItem.screenshot` → `CaptureRegionProvider.run()` →
  `CaptureCoordinator.capture(CaptureRequest(mode: .region))` →
  `captureRegion(delay:)`.
- `CaptureCoordinator.resolveAllDisplays()` grabs a frozen still per display via
  `LegacyScreenCapture` (synchronous CoreGraphics — **not** ScreenCaptureKit, to
  avoid the macOS 26 main-actor executor-corruption crash; this constraint must
  be preserved).
- `SelectionOverlayWindow.present(...)` creates one borderless,
  non-activating `NSPanel` per screen (`SelectionPanel`, `level = .screenSaver`),
  each hosting a `SelectionOverlayView` that draws the frozen still dimmed.
- Interaction today: **drag to create** (`mouseDown` clears the rect,
  `mouseDragged` builds it via `SelectionGeometry.normalizedRect`/`clamped`,
  `mouseUp` commits). No resize handles; adjustment is keyboard-only (arrow keys
  nudge/resize). A magnifier loupe + crosshair guide the cursor.
- The mode toolbar (`CaptureModeBarWindow` + `CaptureModeBarPolicy`) is a
  **separate** floating bar (region/window/fullscreen/timer/recording/scrolling)
  pinned to the bottom of the screen, **not attached to the selection**, opened
  by `CaptureModeBarProvider` → `CaptureCoordinator.presentModeBar()`.
- `lastRegionRect` lives **in memory only** (`CaptureCoordinator.lastRegionRect`),
  reused on `recapture()`; it is **not persisted across launches**.
- `ScrollCaptureCoordinator.capture()` and `RecordingCoordinator.record(region:)`
  run their **own** selection flows and do **not** accept a pre-selected rect.

## 3. Goals / Non-goals

### Goals
- Trigger → immediately show an adjustable selection (last selection, or default
  centered ~50%).
- Resize via 8 handles (4 corners + 4 edges); move by dragging inside; create a
  fresh selection by dragging on empty area.
- Toolbar attached below the selection, following it on move/resize (flipping
  above when there is no room below).
- Toolbar switches capture type: region / window / fullscreen / scrolling /
  recording, and executes on the current selection.
- Persist the last selection rectangle across launches.
- Unify: the new selection+toolbar **replaces** the standalone
  `CaptureModeBarWindow`; the All-In-One entry routes into it.

### Non-goals
- Cross-display selection rectangles (kept per-screen, as today).
- Replacing `LegacyScreenCapture` / introducing ScreenCaptureKit.
- Rewriting the selection overlay in SwiftUI (only the toolbar is SwiftUI).
- Annotation/quick-access overlay changes (the post-capture
  `CaptureOverlayWindow` flow is untouched).

## 4. Decisions (confirmed)

| Topic | Decision |
| --- | --- |
| Scope | **Unify** — new selection+toolbar replaces the standalone mode bar; screenshot and All-In-One share one overlay. |
| Toolbar types | Full set: **region / window / fullscreen / scrolling / recording**. |
| Confirm interaction | **Follow CleanShot X** (see §6). |
| Default + memory | Default **screen-center, ~50% per edge**; last rect **persisted across launches** (UserDefaults). |
| Architecture | **Approach A** — toolbar is an `NSHostingView` subview inside the per-screen selection panel. |

## 5. Architecture (Approach A)

A SwiftUI toolbar is hosted as an `NSHostingView` subview of each per-screen
selection panel, positioned just below the selection rectangle and repositioned
on every move/resize using `OverlayPlacement.frame(forRegion:overlaySize:onScreen:gap:)`
(which already flips above when there is no room below). The background
`SelectionOverlayView` continues to own drawing (frozen still, dim, selection
chrome, handles, loupe) and the selection gestures (handle resize, inside move,
empty-area new drag). Clicks landing inside the toolbar's frame are routed by
AppKit hit-testing to the SwiftUI buttons; clicks elsewhere reach the selection
view's `mouseDown`. One coordinate space, no cross-window synchronization.

Rationale vs. alternatives: a separate tracking toolbar panel (Approach B) adds
cross-window coordinate conversion, z-order, and focus juggling; a full SwiftUI
rewrite (Approach C) would discard the working coordinate/frozen-still/loupe
logic and risk the executor-corruption constraints. Approach A is the smallest,
lowest-risk change. The toolbar may still use `LiquidGlassCompatibility` for a
glass pill background as a subview.

## 6. Interaction model (CleanShot X)

1. **Trigger** → full-screen frozen still + dim, with the selection rectangle
   **already shown**: restored last rect (if its center lies on a connected
   display) else default (screen under cursor, centered, 50% width × 50% height).
2. **Adjust**:
   - 8 handles (4 corners + 4 edges) resize the rect; the opposite corner/edge is
     the anchor.
   - Dragging **inside** the rect moves the whole rect (clamped to the screen).
   - Dragging on **empty area** starts a fresh rectangle (existing drag-create).
   - Arrow keys nudge/resize (existing `SelectionGeometry.moved/resized`).
3. **Toolbar** sits directly below the rect (flips above if no room), follows it,
   and shows 5 type buttons + a W×H dimensions readout.
4. **Confirm / execute**:
   - **Enter** = default action = **region screenshot** of the current rect.
   - **Click a type button** = execute that type **immediately** on the current
     selection:
     - region / scrolling / recording → use the current rect;
     - **window** → switch into window sub-mode (rect + handles + toolbar hidden;
       hover highlights a window; click commits; Esc returns to region mode);
     - **fullscreen** → capture the entire display under the selection.
   - **Esc** = cancel (from window sub-mode, return to region mode first).
5. **Loupe**: magnifier + pixel readout shown during fresh-drag create and during
   handle resize (pixel precision); hidden while merely moving.

## 7. Component design

### 7.1 `CaptureToolType` (new enum, `CaptureTypes.swift`)
```swift
enum CaptureToolType: String, CaseIterable, Sendable {
    case region, window, fullscreen, scrolling, recording
}
```
Drives the toolbar buttons and the selection view's per-type dispatch. Distinct
from `CaptureMode` (which still models the still-grab selection: region/window/
fullscreen) so the still-capture path stays unchanged.

### 7.2 `SelectionHit` / `Handle` + `SelectionGeometry` additions (pure, unit-tested)
```swift
enum Handle: CaseIterable { case topLeft, top, topRight, right,
                                  bottomRight, bottom, bottomLeft, left }
enum SelectionHit { case handle(Handle), inside, outside }

extension SelectionGeometry {
    static func handleRects(for rect: CGRect, handleSize: CGFloat) -> [Handle: CGRect]
    static func hitTest(_ p: CGPoint, in rect: CGRect, handleSize: CGFloat) -> SelectionHit
    static func resizing(_ rect: CGRect, handle: Handle, to p: CGPoint,
                         in bounds: CGRect, minSize: CGFloat) -> CGRect
    static func moving(_ rect: CGRect, by d: CGSize, in bounds: CGRect) -> CGRect
    static func defaultCenteredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect
}
```
`moving` clamps the whole rect inside `bounds` (unlike `moved`, which is a nudge);
`resizing` anchors the opposite handle and enforces `minSize`.

### 7.3 `SelectionOverlayView` (rework)
- Initialize `currentRect` from the provided initial rect (never `.zero` for
  region: fall back to `defaultCenteredRect`).
- `mouseDown` branches on `SelectionGeometry.hitTest`:
  - `.handle(h)` → begin resize (record handle + anchor);
  - `.inside` → begin move (record grab offset);
  - `.outside` → begin fresh drag-create (current behavior).
- `mouseDragged` applies `resizing` / `moving` / `normalizedRect` per active mode;
  after each change, reposition the toolbar subview.
- Draw 8 handle squares on the selection chrome; keep dim/punch-through, crosshair
  (only during fresh drag), and loupe (fresh drag + resize).
- Host the toolbar `NSHostingView`; expose an `onToolType: (CaptureToolType) -> Void`
  callback wired to commit the appropriate `SelectionResult`.
- Window sub-mode reuses the existing hover-highlight logic; entering/leaving it
  toggles the rect/handles/toolbar visibility.
- Cursor reflects the hovered handle (resize cursors) / inside (move) / outside
  (crosshair).

### 7.4 `CaptureSelectionToolbar` (new SwiftUI view, `Views/Capture/`)
- Horizontal glass pill: 5 type buttons (SF Symbols, localized labels) + a
  monospaced W×H readout. Highlights the active type.
- Emits `(CaptureToolType)` on tap. Sized so the host can place it via
  `OverlayPlacement`. Uses `LocalizationManager` / `LocalizedText` for any text
  (UI strings remain Chinese).

### 7.5 `SelectionResult` (extend, `CaptureTypes.swift`)
```swift
enum SelectionResult {
    case region(image: CGImage, rect: CGRect)
    case window(id: CGWindowID, frame: CGRect)
    case fullscreen(displayID: CGDirectDisplayID, frame: CGRect)
    case scrolling(rect: CGRect, displayID: CGDirectDisplayID)
    case recording(rect: CGRect, displayID: CGDirectDisplayID)
    case cancelled
}
```

### 7.6 `CaptureCoordinator` (rework)
- `captureRegion` generalizes into `presentSelection(initialType:delay:)`, used by
  both the screenshot entry and the (now unified) All-In-One entry. It restores
  the persisted last rect, presents the overlay, and routes the `SelectionResult`:
  - `.region` → existing crop + output policy; persist rect to settings.
  - `.window` → `LegacyScreenCapture.window(id)` (existing).
  - `.fullscreen` → `LegacyScreenCapture.display(id)` (existing).
  - `.scrolling` → `ScrollCaptureCoordinator.capture(region:)` (Phase 3).
  - `.recording` → `RecordingCoordinator.record(rect:)` (Phase 3).
- On every committed region rect, write `settings.lastRegionRect`.
- `presentModeBar()` is removed; `CaptureModeBarProvider` calls
  `presentSelection`.

### 7.7 `CaptureSettings` (persistence)
- New key `capture.lastRegionRect`. Stored as a `[Double]` `[x, y, w, h]` in
  global AppKit coordinates (origins may be negative on multi-display setups, so a
  numeric array, not a formatted string).
- `var lastRegionRect: CGRect?` computed accessor over UserDefaults (returns `nil`
  when the key is absent or malformed).

### 7.8 Removed
- `CaptureModeBarWindow`, `CaptureModeBarPolicy` (and their tests) — replaced by
  the attached toolbar. Their digit-key/mode-order behavior is not carried over
  (the new toolbar is click/Enter-driven).

### 7.9 Integration points (Phase 3)
- `ScrollCaptureCoordinator.capture(region: CGRect?)` — accept an optional
  pre-selected region (global AppKit coords) and skip its own selection when set.
- `RecordingCoordinator.record(rect: CGRect?)` — accept a pre-selected region and
  skip its own selection when set.

## 8. Persistence & coordinate spaces

- The selection view works in screen-local AppKit points (bottom-left origin).
- Committed rects convert to global AppKit coords (existing `globalPoint`).
- `lastRegionRect` persists in global AppKit coords. On present: if its center is
  within a connected display, restore it on that display (existing `localInitial`
  mapping); otherwise default to the cursor screen's centered 50% rect.
- The frozen still is pixel space (top-left); crop math via `backingScale` is
  unchanged.

## 9. Phasing

- **Phase 1** — Pre-shown adjustable rect (8 handles + move + empty-area
  new-drag) + cross-launch persistence + default centered 50%, **region
  screenshot only**. Add `SelectionGeometry` handle functions with unit tests.
- **Phase 2** — Attached SwiftUI toolbar (5 types) below the selection,
  following it; wire region / window / fullscreen; Enter / Esc; route the
  All-In-One entry into the new overlay; remove `CaptureModeBarWindow`.
- **Phase 3** — Scrolling + recording receive the current selection (add region
  params to `ScrollCaptureCoordinator` / `RecordingCoordinator`) so their toolbar
  buttons act on the current rect instead of starting a separate selection.

## 10. Testing

- Unit (pure, `AnyDoorTests`): `SelectionGeometry.handleRects`, `hitTest`,
  `resizing` (anchor + minSize + clamp), `moving` (whole-rect clamp),
  `defaultCenteredRect`; `OverlayPlacement` below/above flip; `lastRegionRect`
  encode/decode round-trip; restore-vs-default selection logic.
- Manual: handle resize/move/new-drag across single + multi-display; toolbar
  follow + flip; type switching incl. window sub-mode and fullscreen; Enter/Esc;
  persistence across relaunch.

## 11. Risks / open items

- SwiftUI controls inside a non-activating `.screenSaver`-level panel must
  receive clicks without activating the app — validate early in Phase 2
  (`SelectionPanel.canBecomeKey` is already `true`).
- Phase 3 region handoff depth in `ScrollCaptureCoordinator` /
  `RecordingCoordinator` is unknown; if large, Phase 3 can ship after 1+2 while
  scrolling/recording temporarily keep their existing entries.
- Toolbar must not overlap the selection/handles (kept below with a gap; flips
  above near the screen bottom).
