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

- `PinnedImageLayoutTests` covers initial sizes, all eight resize zones,
  anchored minimum clamping, repeated original-frame deltas, negative screen
  coordinates, and toolbar layout at the minimum size.
- `PinnedImageWindowTests` drives synthetic mouse events through the actual
  AppKit resize handler and checks the resulting panel frame, minimum clamp,
  re-expansion, mouse-up cleanup, and separation from body dragging. It also
  checks click-through routing/state, child-panel positioning/teardown,
  first-click handling, and inactive-application tooltip tracking.
- These tests do not reproduce Window Server hit-testing across applications,
  actual cursor rendering, or real SwiftUI button interaction. Physical checks
  below remain necessary even when the tests pass.
- Run `swift build --build-tests` and `swift test` on macOS. Linux cannot compile
  AppKit or perform native UI validation. PR CI supplies macOS compilation and
  automated tests; complete the manual checks before release.

## Manual checks on macOS 14 and a current macOS version

1. Leave another application active. Pin a screenshot and move over its body,
   each of the four edges, and each of the four corners. The pointer must change
   to a grab hand, horizontal/vertical resize arrow, or matching diagonal arrow.
   Check the same feedback while AnyDoor is active.
2. Drag from all eight resize zones, including the transparent rounded corners.
   Shrink past the opposite edge and verify width never falls below 180 points
   and height never falls below 100 points. Drag back outward without releasing:
   it must expand smoothly from the original anchor, without jumping or drifting.
3. Release, move the body, and resize repeatedly. The first body click must drag
   immediately; resize must not move the whole window. Hovering controls must
   not reset the size. The toolbar must remain aligned to the top-right during
   top/left resize and while moving between displays.
4. Try portrait, tiny, extremely wide/tall, and transparent images. The image
   must retain its aspect ratio; letterboxed areas must still support movement.
   The toolbar must fit at the 180 x 100 minimum.
5. Hover the click-through button while another application remains active.
   Verify the tooltip appears. Enable click-through: the icon must change to a
   slashed cursor with an accent highlight, and the tooltip must offer disabling.
6. Move off the toolbar into the image and another application's controls. Click,
   scroll, and drag the underlying app. Return to the still-visible toolbar and
   disable click-through without using Esc. Repeat several times. Use the opacity
   slider and close button while click-through is enabled; both must remain usable.
   Changing image opacity must not dim the toolbar.
7. Enable click-through on two pins, then press Esc with AnyDoor active and with
   another application active. Where global keyboard monitoring is available,
   both pins must return to normal state and update their icons/tooltips. Even
   without that permission, each toolbar must still disable click-through.
8. Close one pin while click-through is enabled and another is still open. Its
   image, toolbar, and tooltip must disappear; the remaining pin must stay usable.
9. Where available, repeat on differently scaled displays, including one to the
   left/above the primary, and alongside a full-screen application/Space.
