---
id: 001
title: "Image Conversion: core conversion pipeline (tracer bullet)"
status: done
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 3, 4, 7, 8, 9, 10, 14, 15, 17, 18, 20, 28–32, 34, 35, 37, 38)

## What to build

The end-to-end tracer bullet: a new **Image Conversion** builtin of the action kind (panel row, settings visibility/order, recordable hotkey, command-palette entry — all via the existing builtin catalog machinery, mirroring the Translate builtin). Activating it toggles a floating Image Conversion window.

The window holds a **Conversion Basket**: image files can be dragged in (deduplicated by path, non-images ignored), items can be removed individually or cleared, and an empty basket shows nothing broken. A format picker offers the **Target Format Whitelist** (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, PDF, ICO), intersected at runtime with the encoders the system reports. One Convert button converts the whole basket serially off the main thread using ImageIO in-process (no sips, no third-party encoders).

Conversion behavior: output lands beside the source file with the same basename and the new extension; name collisions append a counter (Finder convention); originals are never modified. Edge cases handled in the converter: animated/multi-page inputs use the first frame, ICO output downscales proportionally to the 256 px ceiling, PDF output is a single page wrapping the image, metadata is preserved where the target format supports it. A failed item is skipped, not fatal; a summary toast reports converted/skipped counts.

Window conventions: floating panel that survives losing focus (no outside-click dismissal — dragging from Finder must work), closes on Esc/⌘W, remembers its frame, and is excluded from state restoration (hard project rule). All UI copy localized (Chinese + English) through the string catalog; the feature title is 「图片格式转换」. Use a fixed 85% quality for lossy formats in this slice (the slider arrives in issue 004). Add a CHANGELOG entry under Unreleased and document the new subsystem in the project structure docs.

Naming rule: the subsystem is *Image Conversion* (see `CONTEXT.md` glossary) — do not collide with the existing calculator Conversion services.

## Acceptance criteria

- [ ] The builtin appears in the menu-bar panel, Settings, and command palette, and its hotkey is recordable like any other builtin; activation toggles the window
- [ ] Dragging a WebP/HEIC/PNG file in and converting to JPEG produces `name.jpg` beside the source; converting again produces `name 2.jpg`; the source file is byte-identical afterwards
- [ ] Formats whose encoder the system lacks never appear in the picker
- [ ] ICO output from a large photo decodes to ≤ 256 px on its longest side; an animated GIF converts from its first frame; PDF output is a single-page PDF
- [ ] A basket mixing convertible and unreadable items completes with a toast reporting both counts
- [ ] Esc and ⌘W close the window; the window stays open while Finder has focus; the window is not restored on relaunch
- [ ] Unit tests pass at the agreed seams: session convert-all against real temp files (outputs, naming, counts), plus converter (ICO ceiling, first frame, garbage input throws), format availability filtering, and naming collision policy
- [ ] `swift build` and `swift test` pass; UI strings resolve in both zh-Hans and en

## Blocked by

None - can start immediately
