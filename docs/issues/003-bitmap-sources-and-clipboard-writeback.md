---
id: 003
title: "Image Conversion: bitmap sources, Downloads output, clipboard write-back"
status: in-progress
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 5, 6, 16, 19)

## What to build

Give the Conversion Basket its second payload kind: in-memory bitmaps, alongside file references.

**Paste (⌘V) in the window**: copied image *files* on the pasteboard are added as file references (same behavior as drag & drop); a copied *bitmap* (PNG/TIFF data, e.g. a fresh screenshot) is added as a bitmap item with a generic display name.

**Bitmap output policy**: converted bitmaps are written to the user's Downloads folder, named "Clipboard \<timestamp\>" with the target extension, following the same collision-counter rule as file outputs.

**Clipboard write-back**: after every successful conversion run (regardless of source kind), all output files are placed on the general pasteboard as file URLs — so the user's next ⌘V into a chat or mail attaches them — using the clipboard watcher's self-write suppression so the write-back is not re-recorded into clipboard history.

**Empty state**: an empty basket shows a hint telling the user they can drag images in or press ⌘V.

## Acceptance criteria

- [ ] Copying an image in another app, pressing ⌘V in the window, and converting produces a file in Downloads named `Clipboard <timestamp>.<ext>`; two bitmaps converted in the same run both land with distinct names
- [ ] ⌘V with copied image files adds them as file items (outputs beside originals); ⌘V with non-image clipboard content adds nothing and shows no error
- [ ] After converting, pasting in Finder produces the output files; clipboard history does not record the write-back
- [ ] The empty basket shows the drag/paste hint; it disappears once an item is added
- [ ] Session-seam unit tests cover bitmap items: output lands in an injected downloads directory with the timestamp naming and collision suffixing
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
