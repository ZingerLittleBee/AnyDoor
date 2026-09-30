# Pinned image interactions

Regression checklist for [issue #110](https://github.com/ZingerLittleBee/AnyDoor/issues/110).

## Implementation and automated coverage

Native borderless resizing did not enforce the configured minimum reliably in
manual testing. Resizing now uses explicit 8-point inside-edge/corner hit zones
and immutable starting-frame/screen-delta geometry, with a hard 180 x 100 clamp.
Native window dragging still handles movement from the image body. Image content
stays aspect-fit within the freely resizable panel.

The toolbar is a separate child panel. Click-through disables mouse events only
on the image panel; the toolbar stays visible and interactive until click-through
is disabled. Its icon, accent highlight, accessibility label, and tooltip reflect
the same state. Escape is optional recovery, since global keyboard monitoring may
be unavailable without Accessibility permission.

The image is drawn directly by its AppKit interaction surface, without an
enclosing SwiftUI image host competing for cursor updates. A separate
`activeInActiveApp` tracking area handles `cursorUpdate`; the `activeAlways`
area handles hover/movement. These cannot be combined: AppKit does not send
`cursorUpdate` for `activeAlways`. The image panel also refreshes its requested
cursor after event dispatch, guarded by current frontmost window, visibility,
and click-through state. This changes the application's cursor stack; it does
not grant an inactive application ownership of the displayed pointer. No timer,
global pointer monitor, or application activation is used.

Hovering an interactive image shows eight small, high-contrast resize grips:
four edge pills and four corner grips. The current resize zone and its grip use
an accent highlight, which remains on the original handle throughout a resize.
The grips stay within the existing 8-point resize border and disappear when
the pointer leaves the pin. Crossing the toolbar keeps the grips visible but
clears the resize highlight. Click-through hides all resize feedback immediately;
it never advertises a resize action on the pass-through image.

- `PinnedImageLayoutTests` covers initial sizes, all eight resize zones,
  anchored minimum clamping, repeated original-frame deltas, negative screen
  coordinates, and toolbar layout at the minimum size.
- `PinnedImageWindowTests` drives synthetic mouse events through the actual
  AppKit resize handler and checks the resulting panel frame, minimum clamp,
  re-expansion, mouse-up cleanup, and separation from body dragging. It also
  checks click-through routing/state, child-panel positioning/teardown,
  first-click handling, and inactive-application tooltip tracking.
- `PinnedImageCursorTests` uses the production AppKit panel/surface and an
  injected cursor sink to check cursor-update/after-dispatch routing, all handle
  decisions, tracking-area rebuilds, stationary pointers, and ownership release.
  Recording a cursor choice is not proof of the pointer rendered on screen.
- `PinnedImageResizeAffordanceTests` checks grip geometry against actual hit
  regions and toolbar bounds, production hover/resize/teardown transitions,
  click-through suppression, and nonactivation. Offscreen AppKit drawing checks
  cover the visible grips without treating them as a Window Server cursor test.
- These tests do not reproduce Window Server hit-testing across applications,
  actual cursor rendering, or real SwiftUI button interaction. Physical checks
  below remain necessary even when the tests pass.
- Run `swift build --build-tests` and `swift test` on macOS. Linux cannot compile
  AppKit or perform native UI validation. PR CI supplies macOS compilation and
  automated tests; complete the manual checks before release.

## Passive feedback and the native cursor boundary

Native testing on macOS 27 found that the visible pointer stays an arrow while
AnyDoor is inactive. The diagnostic log showed correct edge/corner selection,
the image panel owning the hit location, and the exact non-arrow `NSCursor.set`
request succeeding in the application's cursor stack. After pinning first,
clicking the AnyDoor Settings title bar, and hovering the same pin edge without
clicking another app, the user confirmed that the visible cursor changed.

This isolates the remaining failure to activation-dependent cursor display;
it is not evidence of a missed resize zone or failed mouse-event delivery.
Apple documents that [NSCursor.current](https://developer.apple.com/documentation/appkit/nscursor/current)
may differ from the visible pointer when another application is active. The
unbundled development launch alone does not establish a packaging defect.

The chosen behavior preserves passive pins: visible resize grips/highlights
provide feedback while AnyDoor is inactive, and normal custom cursor feedback
remains available when AnyDoor is active. Hovering or dragging a pin must not
activate the application. No private cursor APIs or new permissions are used.
An unchanged arrow while AnyDoor is inactive is an accepted platform boundary,
not a claim that background custom cursors have been fixed.

## Manual checks on macOS 14 and a current macOS version

1. Leave another application active. Pin a screenshot and move over its body,
   each of the four edges, and each of the four corners. All eight grips must
   become visible; each edge/corner must highlight its own resize zone and grip.
   The inactive pointer may remain an arrow. The prior app must retain focus,
   including while dragging/resizing the pin. Move off the pin: grips must hide.
   Cross the toolbar: grips remain visible, with no resize highlight underneath
   controls. Repeat immediately after resizing and after switching click-through
   off while the pointer is stationary. Separately activate AnyDoor Settings,
   leave it open, and hover the pin: verify the grab hand and matching resize
   arrows still work. Cross between pins and another application's text/button
   controls; the image must not overwrite the destination's cursor.
2. Drag from all eight resize zones, using the visible areas inside the rounded
   corners. Fully transparent outer-corner pixels belong to the window underneath.
   Shrink past the opposite edge and verify width never falls below 180 points
   and height never falls below 100 points. Drag back outward without releasing:
   it must expand smoothly from the original anchor, without jumping or drifting.
3. Release, move the body, and resize repeatedly. The first body click must drag
   immediately; resize must not move the whole window. Hovering controls must
   not reset the size. The toolbar must remain aligned to the top-right during
   top/left resize and while moving between displays.
4. Try portrait, tiny, extremely wide/tall, and transparent images. The image
   must retain its aspect ratio; letterboxed areas must still support movement.
   The toolbar and grips must fit at the 180 x 100 minimum without overlap.
   Check light, dark, and busy images, including reduced opacity: the grips must
   be discoverable without covering image content away from the resize border.
5. Hover the click-through button while another application remains active.
   Verify the tooltip appears. Enable click-through: the icon must change to a
   slashed cursor with an accent highlight, and the tooltip must offer disabling.
6. Move off the toolbar into the image and another application's controls. Click,
   scroll, and drag the underlying app. Return to the still-visible toolbar and
   disable click-through without using Esc. Repeat several times. Use the opacity
   slider and close button while click-through is enabled; both must remain usable.
   Changing image opacity must not dim the toolbar. No resize grips or highlight
   may remain on the click-through image, including under a stationary pointer.
7. Enable click-through on two pins, then press Esc with AnyDoor active and with
   another application active. Where global keyboard monitoring is available,
   both pins must return to normal state and update their icons/tooltips. Even
   without that permission, each toolbar must still disable click-through.
8. Close one pin while click-through is enabled and another is still open. Its
   image, toolbar, and tooltip must disappear; the remaining pin must stay usable.
9. Where available, repeat on differently scaled displays, including one to the
   left/above the primary, and alongside a full-screen application/Space.

## Opt-in cursor diagnostics

If the pointer still does not change, collect evidence before changing cursor
behavior again. `ANYDOOR_PIN_CURSOR_DEBUG=1` enables transition-only stderr records
prefixed `[PinnedCursor v1]`, capped at 300 records. It does not activate the app,
change hit-testing, add a timer, or change which cursor is requested. Without the
environment variable it is disabled.

Preserve the failing launch identity: `swift run` and the installed app have
separate Accessibility identities. After installing the diagnostic build, quit
any running AnyDoor instance. If the failure is in `/Applications/AnyDoor.app`,
launch that same executable from Terminal:

```sh
ANYDOOR_PIN_CURSOR_DEBUG=1 /Applications/AnyDoor.app/Contents/MacOS/AnyDoor 2>&1 \
  | awk '/^\[PinnedCursor v1\]/ { print; fflush() }' \
  | tee /tmp/anydoor-pin-cursor.log
```

If the failure is specifically in the development launch, use
`ANYDOOR_PIN_CURSOR_DEBUG=1 swift run AnyDoor` as the command before the first pipe
instead. The filter keeps unrelated build/application output out of the shared
log. The first diagnostic line records the process, OS, and bundle identity.

Pin one image, then move once from the image center to the middle of its right
edge, one corner, the toolbar, and outside. Do one sweep with AnyDoor Settings
active and one after activating another application. Quit AnyDoor to end capture,
and share `/tmp/anydoor-pin-cursor.log` together with whether the visible pointer
changed. A screenshot/recording must include the actual pointer; the arrow icon
inside the toolbar is the click-through button, not the pointer.

The log distinguishes callback delivery, hidden/click-through/frontmost-window
rejection, selected handle/body cursor, and the exact `NSCursor.set` call. It
contains local/screen coordinates and transient window IDs, but no captured
image, clipboard content, window title, or other application's identity.
`appCurrentMatchesAfter=true` confirms only AnyDoor's cursor stack. It does not
prove what macOS displayed; an applied request with an unchanged visible pointer
requires investigating rendering/overwrite, rather than treating the log as a
successful cursor fix.
