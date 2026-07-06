---
id: 002
title: "Image Conversion: Finder selection echo + strict hotkey toggle"
status: ready-for-agent
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 1, 2, 21)

## What to build

When the Image Conversion window is summoned (hotkey, panel row, or command palette), read the current Finder selection via AppleScript and echo every image file from it into the Conversion Basket before the window appears. Non-image items in the selection (folders, documents) are ignored silently. Reading happens only at activation time — no live selection tracking.

Failure is silent by design: if the AppleScript call fails (Automation permission not yet granted, Finder not running) or the selection is empty, the window simply opens with an empty basket and no error surface. The system's Automation permission prompt appears lazily on first use.

The hotkey is a strict toggle: if the window is already visible, pressing it closes the window — it does not re-read the selection or append items. Echoed files follow the basket's existing dedupe-by-path rule, so summoning with files already in the basket does not duplicate them.

The AppleScript output parsing must be a pure, unit-testable function (paths in, image-file URLs out); the AppleScript execution itself is not unit-tested.

## Acceptance criteria

- [ ] Selecting several images in Finder and pressing the hotkey opens the window with exactly those images in the basket
- [ ] A selection mixing images, folders, and other files echoes only the images
- [ ] With the window open, the hotkey closes it; reopening after changing the Finder selection shows the new selection
- [ ] With no Finder selection (or Automation permission denied), the window opens empty with no error toast
- [ ] Parsing of the selection-reader output is covered by unit tests (multi-line paths, empty output, non-image filtering)
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
