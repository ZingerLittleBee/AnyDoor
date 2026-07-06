---
id: 007
title: "Image Conversion: screenshot Save As in any whitelisted format"
status: done
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user story 33)

## What to build

Widen the screenshot "Save As" dialog from PNG-only to the full **Target Format Whitelist** (runtime-filtered, same source of truth as the conversion window). The chosen filename extension determines the output format: the captured PNG is transcoded through the shared conversion core on write, using the persisted quality setting for lossy formats. Alias extensions map sensibly (e.g. both `jpg` and `jpeg` mean JPEG). A transcode failure shows a failure toast and writes nothing.

Everything else about the capture pipeline stays PNG: auto-save, clipboard recording, the annotation editor, and the preview overlay are untouched. This slice changes only the Save As path.

## Acceptance criteria

- [ ] The Save As panel accepts every whitelisted, encoder-available format; picking `.heic` writes a real HEIC file, `.pdf` a single-page PDF
- [ ] Saving with `.png` writes the original PNG bytes unchanged (no re-encode)
- [ ] Lossy saves honor the persisted quality percentage from the conversion settings
- [ ] Auto-save output and clipboard-history screenshot recording remain PNG
- [ ] A forced transcode failure surfaces a failure toast and leaves no partial file
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
- 004
