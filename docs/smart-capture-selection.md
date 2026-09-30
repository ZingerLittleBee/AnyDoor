# Intelligent screenshot selection

The unified screenshot action starts in hover selection. It resolves useful
Accessibility controls and containers under the pointer, then offers their
ancestors and the containing window. Tab steps outward; Shift-Tab steps inward.
Both wrap at the ends. Click or Return captures the highlighted target.

Moving at least 5 points during a press switches to free-region selection.
Releasing leaves that region available for resizing, nudging, or the existing
capture toolbar. Return commits it. Once a gesture becomes a drag, returning to
its starting point does not capture the old hover target. Esc cancels; Esc from
the toolbar's explicit Window picker returns to the previous region.

The explicit Window action remains window-only. Scrolling capture retains its
restored viewport/manual-region behavior, including on secondary displays.

## Resolution and fallback

- AX queries run on one dedicated serial queue, with per-message timeouts and
  bounded ancestor traversal. Pointer updates are coalesced every 60 ms, with at
  most one in-flight lookup per overlay and immediate stale-result invalidation
- The foreground CG window is snapshotted before overlays appear. Its owner is
  hit-tested through public application-scoped AX APIs so AnyDoor's frozen
  overlay cannot intercept the hit
- A role policy rejects unusable geometry, tiny/off-screen frames, duplicate
  frames, unrelated parents, and AX roots. Accessibility candidates are clipped
  to the current display/window and captured from the existing frozen image
- The final window candidate retains its actual window frame and the existing
  window capture path. A missing permission or unusable AX tree shows a short,
  localized fallback hint; manual region selection always remains available
- AX and CG geometry stay in global top-left-origin points. Conversion uses the
  primary display's flip height; backing scale is applied only when cropping

## Native verification checklist

These checks require a macOS session with Screen Recording permission and are
not replaced by the pure geometry/scheduler tests:

1. Hover AppKit controls, a Finder sidebar/list, a scroll area, and a sheet.
   Check smallest useful geometry, parent order, reverse cycling, and click crop
2. Move quickly between controls, across displays, and onto a slow/custom-drawn
   app. Check that old results never repaint or get captured
3. Test a secondary display to the left and one above the primary, with mixed
   Retina/non-Retina scale. Compare the highlighted area with the captured pixels
4. Revoke Accessibility permission and repeat in a custom-drawn app. Check the
   distinct fallback hints and window/manual-region paths
5. Press with slight jitter; drag beyond the threshold; drag back to origin;
   release; cancel; reopen. Check that each flow commits or cancels only once
6. Test standalone Window, toolbar Window then Esc, and scrolling capture on a
   different display from its restored rectangle. Existing explicit modes must
   retain their prior meaning
