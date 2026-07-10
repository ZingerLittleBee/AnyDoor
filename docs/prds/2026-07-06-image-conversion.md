# PRD: Image Conversion

- **Status:** implemented — [proposed amendment under review](2026-07-10-image-target-size-compression.md)
- **Date:** 2026-07-06
- **Tracker:** local (`docs/prds/`, issues under `docs/issues/`)
- **Glossary:** [Ubiquitous Language](../../CONTEXT.md#image-conversion)

> **Proposed amendment:** If approved, the 2026-07-10 extension supersedes this
> document's clear-the-whole-basket, list-only window, quality-only
> configuration, non-cancellable run, and Target Size metadata assumptions.
> First-frame conversion remains for Quality mode (with an explicit notice) and
> is rejected only in Target Size mode. This document remains the source for
> the original entry points, additive naming/output locations,
> clipboard-history integration, and format whitelist unless the extension
> explicitly says otherwise.

## Problem Statement

Users constantly receive or produce images in formats that the destination can't accept: a WebP saved from a browser that a chat app rejects, an HEIC from a phone that a web form won't take, a screenshot on the clipboard that needs to be sent as a JPEG file, an image that must become a PDF or an ICO. Today they leave AnyDoor for a converter website or fiddle with command-line tools, breaking the "system-level quick action" promise the app makes for everything else.

## Solution

A dedicated **Image Conversion window** — a floating panel summoned by hotkey or the command palette. Images flow into a **Conversion Basket** from four directions: the current Finder selection is echoed on open, files can be dragged in, clipboard content can be pasted in, and clipboard-history items offer a right-click shortcut. The user picks one target format from a curated **Target Format Whitelist** (with a quality slider for lossy formats), converts the whole basket in one click, and gets the results as new files — beside the originals for file sources, in Downloads for bitmap sources — plus the outputs on the clipboard ready to paste. A capped history of **Conversion Records** lives in the window. Independently, the screenshot "Save As" dialog learns to save in any whitelisted format. Everything runs on the system's ImageIO framework in-process; no `sips`, no third-party encoders.

## User Stories

1. As a user with images selected in Finder, I want to press a hotkey and see those images already loaded in the conversion window, so that I can convert them without any manual picking.
2. As a user, I want the same hotkey to close the window when it is open, so that the shortcut behaves as a predictable toggle.
3. As a command-palette user, I want an "Image Conversion" entry that opens the window, so that I can reach the feature without memorizing a hotkey.
4. As a user, I want to drag image files from Finder (or any app) into the window at any time, so that I can build up a batch incrementally.
5. As a user, I want to press ⌘V in the window to add the clipboard's image or copied image files, so that whatever I just copied can be converted immediately.
6. As a user opening the window with nothing selected, I want an empty-state hint telling me I can drag or paste, so that I'm never staring at a blank panel.
7. As a user, I want to remove any single image from the basket before converting, so that an accidental inclusion doesn't force me to start over.
8. As a user, I want a clear-all control, so that I can reset the basket in one action.
9. As a user, I want to choose the target format from a short list of everyday formats (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, PDF, ICO), so that I'm not hunting through GPU-texture and professional formats I'll never use.
10. As a user on an older system without a given encoder, I want unavailable formats hidden automatically, so that I can never pick a format that will fail.
11. As a user converting to JPEG, HEIC, or AVIF, I want a quality percentage slider (defaulting to 85%), so that I can trade size against fidelity when it matters.
12. As a user converting to a lossless format, I want the quality control hidden or disabled, so that the UI never suggests a meaningless choice.
13. As a returning user, I want the window to remember my last format and quality, so that repeated conversions need zero reconfiguration.
14. As a user, I want one Convert button that processes every image in the basket with the same format and quality, so that a batch is a single decision, not N decisions.
15. As a user converting files, I want each result written next to its source with the same name and a new extension, so that outputs are exactly where I expect them.
16. As a user converting clipboard bitmaps, I want results saved to Downloads with a timestamped name, so that in-memory images gain an obvious on-disk home.
17. As a user, I want name collisions resolved by appending a counter (Finder convention), so that nothing I already have is ever silently overwritten.
18. As a user, I want my original files left untouched no matter what, so that conversion is always additive and risk-free.
19. As a user, I want the converted files placed on the clipboard as files when conversion finishes, so that my very next ⌘V into a chat or email attaches them.
20. As a user, I want a toast summarizing how many images converted and how many were skipped, so that batch outcomes are visible at a glance.
21. As a user who selected a mix of images, folders, and other files in Finder, I want non-images silently skipped and counted, so that a messy selection still converts cleanly.
22. As a clipboard-history user, I want a "convert image format" action on the right-click menu of screenshot and image cards, so that anything captured into history can be re-formatted.
23. As a clipboard-history user, I want the same action on copied image *files*, with output beside the original file, so that file entries behave like Finder conversions.
24. As a user, I want the window to keep the last 50 Conversion Records, so that I can find what I converted and where it went.
25. As a user, I want "Reveal in Finder" on a history record, so that I can jump straight to the output file.
26. As a user, I want "Copy as file" on a history record, so that I can re-share a past output without redoing the conversion.
27. As a user whose output file was later deleted, I want a clear toast instead of a broken action, so that stale history never confuses me.
28. As a user receiving WebP/HEIC/AVIF/RAW images, I want any format the system can decode to be accepted as input, so that "can macOS open it?" is the only rule I need to know.
29. As a user converting an animated GIF or multi-page TIFF, I want the first frame converted, so that the feature does something sensible rather than erroring.
30. As a user converting a large photo to ICO, I want it automatically downscaled to the 256-pixel icon ceiling, so that the conversion succeeds without me knowing ICO's rules.
31. As a user converting to PDF, I want a single-page PDF wrapping my image, so that I can drop images into PDF-only workflows.
32. As a user, I want EXIF/orientation/color-space metadata carried over where the target format supports it, so that photos don't lose rotation or color fidelity.
33. As a screenshot user, I want the "Save As" dialog to accept any whitelisted extension and transcode accordingly, so that a one-off JPEG screenshot needs no separate tool.
34. As a user, I want Esc or ⌘W to close the window, so that it follows the app's established window conventions.
35. As a user who switches to Finder to drag files in, I want the window to stay open while it loses focus, so that drag-and-drop is actually possible.
36. As a user who syncs settings between machines, I want my format and quality preferences included in config backup, so that my setup follows me.
37. As a Chinese or English user, I want the whole window localized like the rest of the app, so that the feature feels native.
38. As a hotkey customizer, I want the Image Conversion shortcut recordable in Settings like every other builtin, so that it fits my existing scheme.

## Implementation Decisions

- **Window-centric model.** One conversion pipeline and one mental model: everything funnels into the Image Conversion window. No per-format hotkeys, no per-format palette entries, no per-format submenus anywhere.
- **Engine is ImageIO, in-process.** `CGImageSource` / `CGImageDestination` end to end. `sips` is explicitly rejected (it is a CLI wrapper over the same framework, and two of the entry points hold in-memory bitmaps, not files). No third-party encoders; WebP therefore remains input-only.
- **Target Format Whitelist** is a hand-curated set of nine formats (PNG, JPEG, HEIC, AVIF, TIFF, GIF, BMP, PDF, ICO), intersected at runtime with the encoders the system actually reports. Input formats are unrestricted — anything ImageIO decodes.
- **New builtin item** of the action kind (mirroring the Translate builtin): it gets a panel row, settings visibility/order, a recordable hotkey, and a command-palette entry for free via the existing catalog/preference/provider machinery. It falls into the default (general) palette group. Its provider toggles the window; on open it reads the Finder selection via AppleScript (Automation permission requested lazily by the system; a failed or empty read opens the window empty, with no error surface).
- **Conversion Basket semantics.** Items are either file references (output beside source) or bitmaps (output to Downloads, timestamped name). File items deduplicate by path. Adding happens via Finder echo, drag & drop, paste, or clipboard-history preload; items are individually removable. The basket clears after a successful run.
- **One config per run.** Format and quality apply to the whole basket. Both persist in user defaults and are whitelisted in the settings-sync registry.
- **Conversion runs serially off the main thread**, one image at a time; failures skip the item and increment a skipped counter rather than aborting the batch.
- **Naming policy** is a pure, injectable module: same-basename-new-extension beside files, "Clipboard \<timestamp\>" in Downloads for bitmaps, " 2"/" 3" suffixing on collision, originals never modified.
- **Edge-case policy:** first frame for animated/multi-page inputs; automatic proportional downscale to 256 px for ICO output; PDF is output-only (single page); metadata is preserved by copying from source where the destination format supports it.
- **History is the sixth SwiftData model** — a Conversion Record stores timestamp, source name, source kind, target format, quality, and output path (never a thumbnail; previews resolve from the output path at render time). The store mirrors the translation-history store pattern (main-actor, observable, revision token, optional context for tests) and trims to 50 records on write. Project documentation stating "exactly five @Model types" must be updated.
- **Post-run behavior:** outputs are written to the general pasteboard as file URLs with the clipboard watcher's self-write suppression, a summary toast reports converted/skipped counts, and one Conversion Record is written per successful item.
- **Clipboard-history integration:** a single context-menu action on wall cards, shown for screenshot/image kinds and for file kinds containing at least one image file. Screenshot/image payloads enter the basket as bitmaps (output → Downloads); file entries enter as file references to their original paths (output → beside original). The wall dismisses before the conversion window opens.
- **Screenshot "Save As"** widens its allowed content types to the whitelist and transcodes on write using the persisted quality. The internal capture pipeline (auto-save, clipboard recording, annotation) stays PNG throughout.
- **Window behavior:** floating panel patterned on the translation window, but with **no** outside-click / resign-key auto-dismiss (drag-and-drop from Finder requires surviving focus loss). Esc, ⌘W, and the hotkey close it. It is excluded from state restoration (hard project rule) and remembers its frame.
- **Localization** through the existing string-catalog pipeline; all UI copy in Chinese and English, no hardcoded strings.
- **Naming disambiguation:** the existing calculator "Conversion" services (unit/currency/time-zone) are untouched; the new subsystem is consistently named *Image Conversion* to avoid collision (see glossary).

## Testing Decisions

Good tests here assert **external behavior at the highest seam**: files appearing on disk with the right names and formats, counts in the returned summary, records in the store — never the internals of ImageIO calls or view state.

- **Primary seam — the conversion session's convert-all operation.** Feed a basket of real temp-dir files and bitmap data; assert real converted files exist at the policy-determined locations, collisions get suffixes, bitmap outputs land in an injected downloads directory, summary counts are exact, and format/quality flow through. This one seam exercises the converter, the naming policy, and the whitelist together against real ImageIO. Prior art: the clipboard history store tests (injected directories, main-actor XCTest).
- **Secondary seam — the history store** against an in-memory model container: insert, 50-cap trimming, revision bumps. Prior art: the translation history store pattern.
- **Pure sub-assertions** only where the primary seam can't reach: ICO pixel-ceiling and quality-affects-size on the converter; encoder-availability filtering with injected encoder IDs; Finder-selection output parsing. Prior art: the capture-filename and calculator test suites.
- **UI is manually verified** (window, palette entry, wall menu, Save As) — consistent with the repo, where no window controller has unit tests.

## Out of Scope

- `sips` or any external process; third-party encoders (hence **no WebP output**).
- Per-format hotkeys, palette entries, or context-menu submenus.
- Per-image format/quality choice within one batch.
- Animated-to-animated conversion (GIF→GIF, HEICS); PDF as *input* (PDF→image is a separate feature).
- Metadata stripping / privacy scrubbing options.
- A quality setting in the Settings window (the in-window slider is the only control).
- Changing the capture pipeline's internal PNG format or its auto-save format.
- Resizing/rotating/editing during conversion (ICO's forced downscale is the sole exception).

## Further Notes

- Encoder availability was verified on the development machine (macOS 26): AVIF, ICO, and PDF encoders are present; WebP encoding is absent — confirming the whitelist and the WebP exclusion.
- The quality default (85%) was chosen as the visually-transparent sweet spot; it is the slider's initial value, not a hidden constant, so no migration is needed if the default changes.
- Basket items are echoed from Finder only at activation time (no live selection tracking) — deliberate, to keep the event-tap callback and window lifecycle simple.
- The feature name in UI copy is 「图片格式转换」; the builtin, window, services, and records all use the *Image Conversion* vocabulary from the glossary.
