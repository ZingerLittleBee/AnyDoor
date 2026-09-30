# Pinned image interactions

Regression checklist for [issue #110](https://github.com/ZingerLittleBee/AnyDoor/issues/110).

## Automated coverage and limitations

- `PinnedImageLayoutTests` covers the initial 360-point size cap, minimum size,
  portrait/landscape/tiny/extreme-aspect captures, and invalid image dimensions.
- `PinnedImageWindowTests` covers native resizing configuration, first-click drag
  acceptance, forwarding the original event, click-through suppression, rejecting
  non-mouse-down events, and AppKit control/surface hit-test precedence.
- These tests do not synthesize a Window Server drag or exercise the real SwiftUI
  control hierarchy. Passing tests alone does not verify physical mouse behavior.
- Run `swift build --build-tests` and `swift test` on macOS. Linux has no AppKit
  and cannot compile or manually validate this window. PR CI provides macOS
  compilation and automated tests; complete the checklist below before release.

## Manual checks on macOS 14 and a current macOS version

1. Capture and pin a landscape image. Leave another application active. Drag
   the image body on the first click, then drag it again. The panel should follow
   the pointer without activating the application or needing a preliminary click.
2. Resize from all four edges and all four corners. Look for native resize
   cursors; the image must preserve its aspect ratio. The window can change aspect
   ratio and show letterboxing. It must stop shrinking at 180 x 100 points.
3. Repeat resize, hover, move, and resize. Hover controls must not snap the window
   back to its initial size or impose the screenshot's original pixel dimensions.
4. Repeat with portrait, tiny, extremely wide/tall, and transparent images.
   Initial width and height must both be at most 360 points. Test dragging in
   letterboxed/transparent areas, and resizing near the rounded corners.
5. Use the opacity slider and both buttons. Slider drags must change opacity
   without moving the panel; the close button must close only that pin. Tooltips
   should explain movement/resizing, opacity, and click-through recovery.
6. Enable click-through and click/drag the application underneath. The pin must
   remain stationary. Press Esc while another application is active, then move,
   resize, adjust opacity, and close the pin again. Also test Esc while AnyDoor
   has keyboard focus. Escape must restore interactivity in either case.
7. Pin two images. Move and resize each independently, use different opacities,
   enable click-through, and close one. The other must remain usable.
8. Where available, drag between displays with different scaling, including a
   display to the left/above the primary, and use a full-screen application/Space.
   Check that movement and native resizing continue to work.

If a supported macOS version does not allow edge/corner resizing on the
borderless resizable panel, record that version and the failed edge/corner before
adding custom resize handling; do not treat style-mask assertions as proof that
the native interaction worked.
