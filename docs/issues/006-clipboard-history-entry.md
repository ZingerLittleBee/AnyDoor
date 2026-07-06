---
id: 006
title: "Image Conversion: clipboard-history right-click entry"
status: ready-for-agent
prd: docs/prds/2026-07-06-image-conversion.md
---

## Parent

PRD: `docs/prds/2026-07-06-image-conversion.md` (user stories 22, 23)

## What to build

A single context-menu action, 「图片格式转换」, on clipboard-wall cards — the funnel from clipboard history into the Image Conversion window. No per-format submenu.

The action appears only on convertible entries:

- **Screenshot and image kinds**: the stored payload enters the Conversion Basket as a bitmap item (so its output follows the Downloads policy), displayed under the card's title.
- **File kind**: shown when at least one contained file has an image extension; those files enter the basket as file references to their original paths (output beside the original), non-image files in the same entry are ignored.

Choosing the action dismisses the clipboard wall first (without restoring focus to the previous app), then opens the conversion window with the items preloaded. If the payload can't be loaded (stored file missing), show a failure toast instead of opening an empty window.

## Acceptance criteria

- [ ] Screenshot and image cards show the action; text/color/QR cards never do
- [ ] A file card containing `photo.webp` and `notes.txt` shows the action; converting loads only the WebP and writes output beside the original file
- [ ] Invoking the action on a screenshot card closes the wall, opens the conversion window with the screenshot preloaded, and converting writes to Downloads
- [ ] A card whose stored payload file is missing shows a failure toast and does not open the window
- [ ] The menu item's title is localized (zh-Hans + en)
- [ ] `swift build` and `swift test` pass

## Blocked by

- 001
- 003
