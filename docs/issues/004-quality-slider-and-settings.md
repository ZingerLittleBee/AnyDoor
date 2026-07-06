---
id: 004
title: "Image Conversion: lossy quality slider + persisted, syncable settings"
status: ready-for-agent
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 11, 12, 13, 36)

## What to build

Replace the fixed 85% quality from the tracer bullet with a user-visible control. The window gains a quality slider (1–100%, initial value 85) that is enabled only when the selected target format is lossy (JPEG, HEIC, AVIF); for lossless formats it is hidden or disabled so the UI never suggests a meaningless choice. One quality applies to the whole basket per run, consistent with the one-config-per-run decision.

Both the last-used target format and the quality percentage persist in user defaults and are restored when the window reopens. Both keys are added to the settings-sync registry whitelist so they travel with config backup/import; they are not machine-specific.

## Acceptance criteria

- [ ] Selecting JPEG/HEIC/AVIF shows an enabled quality slider; selecting PNG/TIFF/GIF/BMP/PDF/ICO hides or disables it
- [ ] Converting the same image at 10% and at 95% JPEG quality produces a visibly smaller file at 10%
- [ ] Closing and reopening the window restores the last-used format and quality; a fresh install defaults to 85%
- [ ] The two settings keys round-trip through config backup export/import
- [ ] Unit tests cover: quality flows through the session seam to output size, defaults/clamping of the persisted values, and registry membership of both keys
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
