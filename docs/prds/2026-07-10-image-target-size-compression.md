# PRD: Target Size Compression and Image Comparison Workspace

- **Status:** proposed — awaiting unified review
- **Date:** 2026-07-10
- **Extends:** [Image Conversion](2026-07-06-image-conversion.md)
- **Technical design:** [Target Size Compression Technical Design](../superpowers/specs/2026-07-10-image-target-size-compression-design.md)
- **Research:** [Target-size compression market research](../research/2026-07-10-image-target-size-compression-market-research.md)
- **Architecture decisions:** [Image I/O backend](../adr/0002-imageio-for-target-size-compression.md), [metadata policy](../adr/0003-target-size-metadata-policy.md), [exact preview reuse](../adr/0004-exact-preview-reuses-final-candidate.md)
- **Glossary:** [Ubiquitous Language](../../CONTEXT.md#image-conversion)

## Problem

Image Conversion currently exposes encoder quality, but many destinations impose
a byte limit instead: an avatar must be below 500 KB, an upload below 2 MB, or an
attachment below a service-specific cap. Users must guess a quality, convert,
inspect the file, and repeat. The current list-only window also provides no visual
evidence of what a lossy conversion changed.

The feature must let users choose a Per-Output Limit and obtain the best candidate
found within it without silently resizing, dropping transparency, changing HDR,
or claiming an oversized file succeeded. It must also make ordinary Quality
conversion visually inspectable through the same interface.

## Outcome

Image Conversion becomes one three-column workspace with two persistent modes:

1. **Quality** retains the existing format whitelist and explicit quality value.
2. **Target Size** performs a bounded Image I/O search over JPEG, HEIC, or AVIF
   candidates. Optional Resize Fallback may reduce dimensions only after the
   format's internal Quality Floor is reached.

Both modes provide an exact, full-resolution original/result comparison for the
selected basket item. When source and configuration are unchanged, the preview
candidate is the file committed by the Conversion Run.

## Goals

- Accept a positive target in decimal KB or MB and apply it independently to
  every output in a batch.
- Select the highest-quality candidate measured at the pixel size chosen by the
  documented bounded-search policy.
- Keep original dimensions unless the user explicitly enables Resize Fallback.
- Preserve display-critical information, remove ancillary metadata in Target
  Size mode, and make any HDR-to-SDR conversion visible.
- Make lossy tradeoffs inspectable in both modes.
- Never modify a source, overwrite an existing output, or expose a partially
  written final file.
- Keep expensive work responsive, cancellable, serial, and bounded.

## Non-goals

- Third-party encoders, `sips`, cloud compression, or WebP output.
- Target-size control for PNG, TIFF, GIF, BMP, PDF, or ICO.
- Animated or multi-page conversion. Quality mode's existing first-frame-only
  output remains; it does not extend to Target Size.
- Per-item formats, quality values, byte limits, or backgrounds in one batch.
- User-facing Quality Floor, Pixel Floor, iteration count, or encoder-debug view.
- Content classification or different algorithms for photos and screenshots.
- Persistent baskets or resuming an interrupted run after the app exits.
- A mathematical claim that Image I/O's quality scale is globally monotonic or
  perceptually comparable across different pixel dimensions.

## Product Contract

### Modes and defaults

- A segmented control switches between **Quality** and **Target Size**.
- The last mode is remembered. The default remains Quality for compatibility.
- Each mode remembers a separate target format.
  - Quality keeps the existing runtime-filtered format preference.
  - Target Size defaults to JPEG and offers only runtime-available JPEG, HEIC,
    and AVIF.
- Quality remains a whole percentage from 1 through 100 and defaults to 85.
- Target Size defaults to `1 MB`.
- Resize Fallback is always visible in Target Size, defaults off, and remembers
  the user's later choice.
- Transparency Background defaults to opaque sRGB white and remembers the last
  chosen color.
- Mode, both formats, quality, target bytes/unit, Resize Fallback, and
  Transparency Background participate in configuration backup/sync. Window and
  canvas state do not.

### Target input

- The field accepts localized positive decimal input with at most two fractional
  digits.
- `KB` means 1,000 bytes and `MB` means 1,000,000 bytes, matching Finder-style
  file-size language.
- Conversion uses an exact integer-byte limit derived with decimal arithmetic,
  never binary floating point.
- Changing the unit converts the displayed number so the effective byte limit
  never changes. The stored integer bytes remain exact; the displayed value may
  round to two fractional digits, and re-parsing happens only when the user
  edits the field.
- Zero, negative, malformed, or overflowing input displays an inline error and
  disables preview generation and conversion.
- Target success has no above-limit tolerance: final bytes must be less than or
  equal to the Per-Output Limit.

### Batch behavior

- One mode, target format, and configuration apply to the whole Conversion
  Basket.
- Target Size applies the same absolute limit independently to every item; byte
  budgets are never pooled.
- Lightweight preflight checks the entire basket before conversion. Incompatible
  items are marked and skipped without blocking compatible items.
- V1 processes compatible items serially in basket order.
- A run freezes its configuration and item snapshot. Add/paste/drop, remove,
  clear, and configuration changes are disabled until completion or Stop.
- Successful items remain visually stable during the run, then leave the basket
  together. Best-Effort, unsupported, encoding-failed, and write-failed items
  remain for retry.

### Source compatibility

- Inputs must contain a raster image that Image I/O can decode.
- Quality mode keeps the original first-frame contract for multi-frame and
  multi-page sources: the first image is converted, the basket row shows a
  first-frame-only notice before the run, and the Conversion Record retains
  that fact.
- Target Size rejects any source with more than one frame or page before
  preview or output creation, with a reason stating that the mode does not
  support animated or multi-page input. Target Size never produces a partial
  first-frame result.
- PDF input remains out of scope even when Image I/O can rasterize one page.
- RAW and other system-decodable single-image inputs are accepted when preflight
  can obtain their pixels and display properties.
- Runtime encoder availability is authoritative; unavailable formats are hidden.

### Transparency

- JPEG is treated as non-alpha. HEIC/AVIF alpha capability is verified at runtime
  and on the minimum supported macOS release.
- If any basket item has alpha and the selected target cannot preserve it, one
  shared **Transparency Background** control appears in the inspector and states
  how many items it affects.
- Encoding explicitly composites against that color. It never relies on Image
  I/O's implicit white default.
- Original alpha is displayed over a checkerboard. The Result pane shows the
  exact preserved-alpha or composited output.
- If a real encoder contradicts preflight's cached alpha capability, the item is
  not silently recompressed. It remains in the basket, capability/preflight is
  refreshed, and the background control is surfaced for an explicit retry.

### HDR and color

- When a target cannot preserve source HDR/gain-map content, conversion remains
  available with a persistent warning: the result will be SDR and brightness or
  color may change.
- The exact Result preview shows the SDR candidate, the basket marks affected
  items, and the Conversion Record stores `hdrToSDR`.
- Failure to preserve orientation or intended color is an encoding/policy
  failure, not another silent downgrade category.

### Metadata

Quality mode keeps its existing preserve-where-supported metadata policy. Target
Size uses one stable privacy and byte-budget policy:

- preserve or normalize orientation, preserve intended color, and retain
  supported HDR/gain-map data;
- remove GPS, EXIF capture details, MakerNote, IPTC/XMP, embedded thumbnails,
  comments, and other ancillary metadata;
- include all retained metadata in every measured candidate's bytes.

For a same-format source already under the limit, Target Size first attempts a
Pass-Through Result. The copied container is reopened and audited. Unsupported or
ineffective metadata removal, display-policy failure, or an oversized rewrite
falls back to the ordinary bounded search.

### Outcomes

| Outcome | Final file | Conversion Record | Clipboard | Basket |
| --- | --- | --- | --- | --- |
| Success | Yes | Yes | Included | Remove after run |
| Pass-Through Result | Yes | Yes | Included | Remove after run |
| Best-Effort Result | Only on explicit save | Only on explicit save | Excluded | Keep |
| Unsupported | No | No | Excluded | Keep |
| Source/capability changed | No | No | Excluded | Keep and re-preflight |
| Encode failure | No | No | Excluded | Keep |
| Write failure | No final file | No | Excluded | Keep |
| Cancelled current/unstarted item | No | No | Excluded | Keep |

- A Best-Effort Result is the smallest measured candidate within the user's
  configuration and internal policy limits. It is never written to disk
  automatically: the candidate is retained as a private artifact, and the
  inspector offers explicit **Save Anyway** and **Copy as File** actions. Save
  Anyway commits that exact candidate through the normal output path and only
  then creates its Conversion Record. The run summary offers a save-all action
  when a batch produced several Best-Effort Results.
- A retained Best-Effort artifact lives as long as its basket item: it survives
  window hiding and run completion, and is discarded when the item is removed,
  a newer candidate replaces it, or the app exits. Every file on disk is one
  the user explicitly accepted.
- A within-limit result may be larger than its source when changing format. It
  still succeeds because the contract is an absolute limit, not guaranteed
  savings; the inspector displays the growth plainly.
- Successful URLs reach the clipboard in basket order when a run completes or
  stops. With no successful output, the existing clipboard is untouched.
- A history-save failure is a secondary warning. It never deletes the committed
  file or changes that file's basket/clipboard outcome.

## Workspace

### Window and layout

- The existing floating, non-restorable panel remains resizable and survives
  focus loss.
- Default content size is 1,200 × 740 points; minimum size is 960 × 600 points.
  Restored legacy frames are clamped to the new minimum and visible screen.
- The toolbar becomes one title row. Configuration moves to the inspector.
- The body is stable:
  1. Conversion Sidebar, initially 220 points and adjustable from 190 to 280;
  2. Comparison Workspace, filling available space;
  3. a fixed 280-point Conversion Inspector with internal scrolling.
- The original/result divider starts at 50/50, stays within 25%...75%, and saves
  its normalized ratio locally.
- Sidebar and inspector use structural material. The comparison canvas stays
  stable and opaque rather than nesting glass cards.

```text
┌────────────────────────────────────────────────────────────────────┐
│ Image Conversion                                            Status │
├──────────────┬──────────────────────────────────┬──────────────────┤
│ Basket /     │ Original          │ Result       │ Inspector        │
│ History      │                   │              │ Mode             │
│              │                   │              │ Format           │
│ Items and    │ synchronized comparison          │ Settings         │
│ status       │                   │              │ Warnings/metrics │
│              │                   │              │                  │
│ Add / Clear  │ zoom controls and dimensions     │ Convert / Stop   │
└──────────────┴──────────────────────────────────┴──────────────────┘
```

### Sidebar and history

- A segmented control switches between **Basket** and **History**. Basket is the
  default whenever the window is presented.
- The first item added to an empty basket becomes selected. Later additions do
  not steal selection; removal selects the nearest remaining item.
- Basket rows show thumbnail, name, source size/dimensions when available, and
  text/icon state for inspection, warning, active conversion, target miss, or
  failure. Ordinary compatible rows avoid redundant green badges.
- History remains capped at 50 output records. Selecting one changes the center
  to a single-output viewer and the inspector to record details/actions.
- Reveal in Finder and Copy as File are available while an output exists. A
  later-deleted output shows **Missing Output** and disables both actions.
- Returning to Basket restores its prior selection and comparison state.
- Dragging anywhere over the idle window shows one drop overlay. `⌘O` and the Add
  button provide a keyboard/VoiceOver-accessible file picker.

### Exact comparison

- The workspace is a user-resizable horizontal split with Original on the left
  and Result on the right.
- Pan shares one normalized focal point. Zoom is anchored to the source image:
  **100%** means one original pixel per backing pixel in the Original pane, while
  the Result pane scales proportionally to show the same normalized field of
  view. A resized result may therefore be magnified at source 100%.
- Both panes start fitted. Fit, source-100%, trackpad magnification, scroll/pan,
  Space-drag/direct drag, and keyboard zoom update both panes. The range is
  10%...800% relative to source 100%.
- Preview is generated only for the selected basket item after a short debounce.
  Obsolete work cannot replace a newer state.
- The preview is a full-resolution final-pipeline candidate with exact bytes and
  dimensions. A matching run commits the same artifact without recompression.
- While replacement is running, the last preview may remain dimmed with an
  explicit **Updating** label. Stale metrics are never presented as current.
- Empty, checking, updating, ready, target reached, resized, Best-Effort Result,
  invalid configuration, unsupported, and failed states have distinct visible
  and accessible descriptions.

### Inspector

Controls remain in this order:

1. Conversion Mode.
2. Mode-specific target format.
3. Quality, or target value/unit plus Resize Fallback.
4. Transparency Background when required.
5. Persistent compatibility/HDR/privacy notices.
6. Selected-item result summary.
7. **Convert All**, pinned to the bottom.

The summary shows source/result size, savings or growth, source/result dimensions,
format, target status, Resize Fallback use, and HDR-to-SDR state. Encoder search
iterations and internal floors are not user-facing.

A Best-Effort summary must state what stopped the search and what to do next.
With Resize Fallback off, it explains that quality adjustment alone cannot reach
the target and embeds an inline control that enables Resize Fallback and
refreshes the preview. With Resize Fallback already on and the internal minimum
dimension reached, it states plainly that the target is unattainable for this
image and offers no false suggestion. The Save Anyway and Copy as File actions
appear with the Best-Effort summary.

During a run, configuration controls are disabled and the primary button becomes
**Stop**. The inspector shows item progress, current filename, and an honest phase
such as Preparing, Compressing, Resizing, or Writing. It does not invent a
single-image percentage that Image I/O cannot report.

## Cancellation and Lifecycle

- Stop changes immediately to **Stopping…**. It takes effect after the current
  synchronous Image I/O candidate or final commit boundary.
- Completed outputs remain valid. The interrupted and unstarted items remain in
  the basket; there is no batch rollback.
- Cancellation immediately before the irreversible output commit produces no
  file. Once commit succeeds, that item is completed and receives its normal
  record/basket/clipboard effects before later items stop.
- Closing the window only hides it. Reopening shows the same run and Stop state.
- Explicit app termination abandons unfinished work without exposing partial
  final files. Completed outputs remain; stale private artifacts are removed on
  normal shutdown or by startup cleanup after a crash.

## Keyboard, Accessibility, and Motion

- Focus follows sidebar, workspace controls, then inspector. The current
  root-level `.focusEffectDisabled()` is removed.
- `⌘0` fits, `⌘1` selects source 100%, and `⌘+`/`⌘-` zoom.
- `⌘O` opens files, `⌘Return` starts a valid run, and `⌘.` requests Stop.
- `⌘V`, Return, Esc, and Delete respect active text/picker/list focus before
  window-level shortcuts. Pasting into the target field must not add an image.
- Every pane, state, warning, metric, and icon-only action has localized
  accessibility text. Status never depends on color alone.
- Direct manipulation has no spring or inertial bounce. Reduce Motion removes
  spatial transitions; Reduce Transparency uses a more opaque structural
  background.
- Preview/result/run completion announcements occur once per meaningful state,
  not on every slider tick or candidate.

## Acceptance Criteria

- A Target Size Success or Pass-Through Result is always within the exact integer
  Per-Output Limit after final metadata/alpha policy.
- An unattainable target yields a clearly labeled Best-Effort Result that is
  written to disk only through an explicit user action, never labeled Success,
  and never automatically copied to the clipboard.
- A Best-Effort summary always states whether quality search or the minimum
  dimension stopped the search, and offers the inline Resize Fallback control
  only when enabling it could still help.
- Resize Fallback is never used while off, remains proportional while on, and
  never crosses the internal Pixel Floor.
- The source and every pre-existing output remain byte-for-byte untouched,
  including during naming races and failed writes.
- Matching exact preview and final output are byte-identical; a changed source,
  configuration, capability, or policy invalidates reuse.
- JPEG uses the selected Transparency Background. HEIC/AVIF preserve alpha only
  when the current runtime proves it.
- Target Size removes ancillary metadata and preserves/audits orientation and
  intended color. HDR is preserved or recorded and shown as HDR-to-SDR.
- PDF input produces no preview or output in either mode. Multi-frame/
  multi-page input converts first frame only — with a visible notice and a
  recorded fact — in Quality mode, and produces no preview or output in Target
  Size.
- Mixed batches keep exact item order and outcome-specific basket/history/
  clipboard behavior.
- Stop responds no later than the current synchronous candidate/commit boundary,
  and closing the window does not stop a run.
- Legacy Conversion Records fault without migration failure and retain their
  previous values.
- All new user-facing text is localized through `L10n`/the string catalog.
- Platform capability, calibration, memory, latency, candidate-budget, atomic
  writer, migration, and real Image I/O gates in the technical design pass.

## Superseded Original Decisions

This extension intentionally replaces these rules from the original Image
Conversion PRD:

- first-frame conversion remains in Quality mode (now with an explicit basket
  notice and recorded fact) but is rejected in Target Size mode;
- clearing the entire basket becomes outcome-specific removal;
- list-only content and fixed bottom history become the three-column workspace;
- quality-only configuration becomes two persisted modes;
- non-cancellable runs become candidate-boundary cancellation;
- Target Size metadata follows the explicit display-critical/ancillary policy;
- resizing remains non-implicit, but an explicit remembered Resize Fallback is
  now available.

Original entry points, additive output locations/naming, clipboard-history
integration, runtime format filtering, localization, and non-restorable window
behavior remain unless this document says otherwise.

## Approval Gate

This PRD contains no unresolved product choice. The accompanying technical design
contains the bounded engine, migration, atomic-write, cache, calibration, and
verification details. Both remain proposed until unified review approves them;
implementation does not begin before that approval.
