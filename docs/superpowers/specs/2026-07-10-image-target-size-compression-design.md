# Target Size Compression Technical Design

- **Status:** approved — unified review passed 2026-07-10
- **Date:** 2026-07-10
- **Product contract:** [Target Size Compression PRD](../../prds/2026-07-10-image-target-size-compression.md)
- **Research:** [Market and Image I/O research](../../research/2026-07-10-image-target-size-compression-market-research.md)
- **ADRs:** [Image I/O backend](../../adr/0002-imageio-for-target-size-compression.md), [metadata policy](../../adr/0003-target-size-metadata-policy.md), [exact preview reuse](../../adr/0004-exact-preview-reuses-final-candidate.md)

## Design Priorities

1. The final file must obey the product outcome contract. Target success means
   final bytes are no greater than the Per-Output Limit.
2. Preview and final output must be the same immutable candidate when their
   source and configuration fingerprints match.
3. No source or existing output may be overwritten, including during a naming
   race with another process.
4. Image I/O, decoding, hashing, and file work never run on the main actor.
5. Memory, encoded-candidate count, and cancellation latency are bounded.
6. The SwiftData migration must fault existing Conversion Records safely.

## Module Boundary

The UI observes one main-actor owner and sends immutable requests into one
serialized engine actor.

```text
ImageConversionViewModel (@MainActor, @Observable)
    ├── basket, selection, navigation and presentation state
    ├── source/preview/run task handles and generation tokens
    ├── frozen run configuration and item snapshot
    └── history, pasteboard and toast side effects
                         │
                         ▼
ImageConversionEngine (actor)
    ├── ImageIOSourceInspector
    ├── ImageIOCapabilityCache
    ├── TargetSizeSearch
    ├── ImageIOCandidateEncoder
    ├── TargetMetadataPolicy
    ├── CandidateArtifactStore / fingerprint job registry
    └── AtomicOutputWriter
```

There is no public encoder protocol in V1. Image I/O is the only backend, and
the deep engine boundary is sufficient until a measured second implementation
exists. `CGImageSource`, `CGImageDestination`, `CGImage`, mutable Core
Foundation data, and `NSImage` never cross the actor boundary.

Cross-actor values are immutable and `Sendable`:

- `ImageConversionConfiguration`
- `SourceFingerprint` and `ConfigurationFingerprint`
- `PixelDimensions`
- `PreflightResult` and `PreflightIssue`
- `PreparedCandidate` and `CandidateSummary`
- `ImageConversionItemOutcome` and `ImageConversionRunSummary`
- `ImageConversionProgress`

The presentation model composes four orthogonal states instead of one
combinatorial enum:

```text
NavigationState × SourceState × PreviewState × RunState
```

## Configuration

Use closed value types rather than loosely related fields:

```swift
enum ImageConversionConfiguration: Hashable, Sendable {
    case quality(QualityConfiguration)
    case targetSize(TargetSizeConfiguration)
}
```

`QualityConfiguration` contains target format, whole-percent quality where
applicable, and Transparency Background. `TargetSizeConfiguration` contains a
Lossy Target, `Int64` target bytes, Resize Fallback, and Transparency Background.
Both carry metadata-policy and compression-policy versions in their fingerprint.

The V1 compression policy is version 1:

| Setting | Value |
| --- | --- |
| JPEG Quality Floor | 40 |
| HEIC Quality Floor | 45 |
| AVIF Quality Floor | 45 |
| Pixel Floor | 640 px longest edge |
| Quality probes at a searched size | At most 9 |
| Resize levels | At most 6 |
| Total finalize/copy attempts | At most 17 |
| Resize headroom | 0.95 |
| Per-step scale clamp | 0.25...0.90 |
| Preview debounce | 300 ms |

These are conservative V1 starting values. The calibration gate may raise a
Quality Floor before release. Lowering a floor or changing candidate ordering
requires a new documented visual review and a policy-version bump.

## Source Fingerprint

A preview may be reused only if the source is proven unchanged.

For file inputs, the fingerprint contains:

- standardized path;
- resource identifier;
- file size and modification date;
- streaming SHA-256 content digest.

For in-memory bitmaps, it contains the stable basket ID and content digest. The
engine computes the digest while reading the source and revalidates it
immediately before final commit. A mismatch discards the candidate. The frozen
run prepares no replacement: it returns `sourceChanged`, refreshes preflight,
and leaves the item in the basket for explicit retry. Hashing is streamed and
never loads an entire file solely to hash it.

## Preflight and Capability Cache

Preflight is lightweight and does not create full conversion candidates. It
checks:

- the source still exists and is decodable;
- frame count against the mode contract: Target Size requires
  `CGImageSourceGetCount == 1`; Quality accepts multi-frame/multi-page sources
  and marks the item first-frame-only so the basket notice appears before the
  run;
- the source is not PDF input;
- the selected destination encoder is currently available;
- output placement can be resolved;
- source dimensions, byte count, alpha and HDR/gain-map presence;
- whether target alpha handling requires Transparency Background.

JPEG is known non-alpha. HEIC and AVIF run a tiny per-format round-trip probe on
first use and cache the result with the runtime/OS capability version. The same
probe is exercised on macOS 14 and 26 before release.

Capability discovery is part of the frozen configuration contract. If a real
candidate later contradicts the cached alpha capability, the engine does not
silently add compositing or exceed the candidate budget. It returns
`capabilityChanged`, invalidates the cache, reruns preflight, and leaves the item
in the basket. The inspector then surfaces Transparency Background before the
user retries. Preview generation may restart only after that state is visible.

## Candidate Encoding

Each attempt creates a destination in mutable memory, finalizes it, measures
bytes, and performs only cheap structural inspection. The current mutable
buffer is released after the attempt. When a candidate becomes the best
qualifier or smallest Best-Effort Result, it is materialized as a private
temporary artifact with immutable byte-count and SHA-256 metadata, and the prior
displaced artifact is deleted. Ordinary Target Size encoding rebuilds output
from decoded pixels plus explicit display properties; it does not inherit the
source's full metadata dictionary.

Only the selected final candidate and lossless pass-through candidates receive
the full audit:

- output is decodable and has the expected pixel dimensions;
- final bytes match measured bytes;
- Target Size ancillary metadata is absent;
- orientation and intended color are preserved or normalized correctly;
- alpha matches the frozen capability/compositing policy;
- HDR/gain-map presence is preserved, or `hdrToSDR` is recorded.

This avoids 17 full decode-and-scan passes. Audit failure is not silently
accepted. Metadata/orientation/color failure produces a policy failure;
alpha-capability mismatch follows the preflight-refresh path; missing HDR becomes
the explicit Display Downgrade allowed by the product contract.

At most one mutable encoding buffer, one best-qualifying artifact, and one
smallest-best-effort artifact exist during a search. The two stored roles may
refer to the same artifact. The displayed preview is the selected artifact, not
an additional byte copy.

## Same-Format Pass-Through

When source and target formats match and the source is already within the limit:

1. Attempt `CGImageDestinationCopyImageSource` with the Target Size metadata
   policy.
2. Count this copy/finalize as one of the 17 attempts.
3. Reopen the result and run the complete metadata/display/byte audit.
4. Return Target Reached only when the audit passes and bytes remain within the
   limit.
5. Otherwise discard it and enter ordinary bounded re-encoding.

JPEG is expected to support the lossless metadata rewrite. Current probes show
that HEIC may leave GPS behind and AVIF may reject the operation; audit, not the
format name, decides whether the candidate qualifies.

## Target-Size Search

Quality is an integer percentage so boundaries and cache keys are deterministic.
Image I/O size monotonicity is a search hint, not a contract. The search always
retains:

- the highest-quality measured candidate at or below target for the currently
  selected pixel size;
- the smallest measured candidate overall.

Ordering is explicit:

1. At original dimensions, search down only as far as the Quality Floor.
2. If original dimensions cannot fit and Resize Fallback is enabled, maximize
   pixel dimensions subject to the Quality Floor.
3. At that largest fitting pixel size, maximize measured encoder quality.

Quality numbers are not compared across different dimensions as if they were a
perceptual metric. This ordering implements “do not cross the Quality Floor,
then resize” without pretending that a smaller q100 universally looks better
than a larger q46.

Algorithm:

1. Optionally attempt the same-format pass-through.
2. At original dimensions, encode quality 100. Return if it fits.
3. Encode the format's Quality Floor.
4. If the floor fits, binary-search whole-percent quality with a strict
   nine-attempt-at-this-size cap, including boundaries and one adjacent-boundary
   probe. Return the highest-quality measured qualifier.
5. If the floor is oversized and resizing is disabled, return the smallest
   measured artifact as Best-Effort Result.
6. If resizing is enabled, compute:

```text
estimatedScale = clamp(
    sqrt(targetBytes / floorCandidateBytes) × 0.95,
    0.25,
    0.90
)
nextLongestEdge = max(640, floor(currentLongestEdge × estimatedScale))
```

7. Preserve aspect ratio, clamp the short edge to at least 1 px, and always
   resample from the original decoded image rather than a previous resized
   candidate. If the original longest edge is already at or below 640 px, do not
   resize.
8. At each smaller level, first encode only the Quality Floor. The first level
   whose floor candidate fits receives the bounded quality search. Do not explore
   smaller levels afterward.
9. Stop at success, 640 px, six resize levels, or 17 total attempts. If nothing
   fits, return the smallest measured artifact. Equal byte counts prefer more
   pixels, then higher quality.

A Best-Effort `CandidateSummary` carries an explicit stop reason —
`qualityFloorReached` (resizing was off or unavailable) or `pixelFloorReached`
(resizing was on and exhausted) — so the inspector can offer the inline Resize
Fallback control only when enabling it could still help. The reason is derived
from search state the engine already tracks; no extra encoding is performed.

The 17-attempt worst case is:

```text
1 pass-through
+ 2 original probes
+ 5 failed resized-floor probes
+ 9 probes at the sixth fitting level
= 17 attempts
```

Without pass-through the maximum is 16. Every destination copy/finalize attempt,
including one rejected by final audit, consumes the budget.

## Exact Preview Job Registry

Candidate jobs are owned by an engine/session registry keyed by source and
configuration fingerprints. Preview and run are consumers, not owners of the
underlying Swift task.

- A UI selection/configuration change cancels only that preview consumer's wait.
- With no run consumer, obsolete work is cancelled at the next candidate
  boundary.
- When a run attaches to the same fingerprint, the job continues even if the
  preview consumer disappears.
- A matching completed artifact commits with zero additional encodes.
- A fingerprint mismatch invalidates and deletes the artifact.
- The generation token and both fingerprints must still match before a preview
  updates UI state.

The artifact store retains at most one displayed candidate and one in-flight
job for the selected item, plus at most one retained Best-Effort artifact per
basket item that produced a target miss. Removing an item, clearing/resetting
the session, or hiding an idle window removes stale preview artifacts; a
retained Best-Effort artifact instead follows its basket item's lifetime — it
survives window hiding and run completion, and is deleted when the item is
removed, a newer candidate replaces it, or the app exits. Save Anyway and Copy
as File consume this artifact without re-encoding. Active-run artifacts survive
window hiding. A startup janitor removes AnyDoor session directories older than
24 hours after a crash; directory permissions are limited to the current user.

## Serial Run and Cancellation

The engine actor serializes preview and batch Image I/O work. There is no
`Task.detached`, task group, manual lock, or concurrent per-item encoding.

A run freezes configuration and eligible basket order. Add/paste/drop, remove,
clear, and configuration changes remain disabled until completion or Stop.

The task checks cancellation:

- before and after each candidate finalize;
- between resize levels and items;
- before staging a final write;
- once more immediately before the exclusive commit operation.

Image I/O finalize is synchronous and cannot be interrupted. Stop therefore
changes UI to Stopping immediately but takes effect after the current finalize.

The exclusive rename/link is the single irreversible commit point:

- cancellation before it deletes staging and leaves no output or record;
- a successful commit makes the item completed even if cancellation arrives one
  instruction later; history and basket/clipboard effects must finish for that
  item before the run stops subsequent items.

## Atomic Output Writer

The output writer receives an immutable candidate artifact and destination
policy. It owns naming and commit as one operation, eliminating the current
check-then-write race.

1. Open the target directory once and create a hidden UUID staging name relative
   to that directory descriptor with
   `openat(O_CREAT | O_EXCL | O_NOFOLLOW, 0600)`. On `EEXIST`, choose a new UUID;
   UUID probability is never treated as the no-overwrite guarantee.
2. Stream the complete candidate into that descriptor while calculating byte
   count and SHA-256. Compare both with the immutable candidate before commit;
   any mismatch deletes staging and returns write failure with no visible output.
3. Flush the verified staging inode and directory metadata required for
   durability.
4. Check cancellation for the final time.
5. On supported macOS filesystems, call `renameatx_np(..., RENAME_EXCL)` relative
   to the same target-directory descriptor.
6. On `EEXIST`, reuse the same verified staging inode and try the next
   Finder-style name.
7. If exclusive rename is unsupported, call `linkat(staging, final)` relative to
   the same directory descriptor; its atomic
   `EEXIST` behavior reserves the final name without replacement, then unlink the
   staging name.
8. If neither exclusive rename nor hard-link creation is supported, return a
   write failure. V1 never falls back to a TOCTOU-prone move that might replace a
   competing file.
9. On every failure before commit, delete staging with `defer`.

Successful rename/link is the end of the fallible content path: it exposes the
same already-verified inode. No post-commit path-based re-read may turn a visible
final file into a retroactive write failure.

The writer never combines Foundation `.atomic` and `.withoutOverwriting`, never
modifies the source, and treats same-extension sources, symlinks, and names
claimed by another process as collisions.

## Per-Item Outcomes

```swift
enum ImageConversionItemOutcome: Sendable {
    case success(CommittedOutput)
    case targetMiss(BestEffortCandidate)
    case unsupported(PreflightIssue)
    case failed(ImageConversionFailure)
    case cancelled
}
```

`targetMiss` is not an error, but it commits nothing: it carries the retained
Best-Effort artifact reference (immutable byte count, SHA-256, metrics, and
stop reason), not a `CommittedOutput`. An explicit Save Anyway commits that
artifact through the same `AtomicOutputWriter` and only then creates the
Conversion Record. Only success is clipboard-eligible and removed from the
basket. Target miss, unsupported, and failure remain. Cancelled
current/unstarted items produce neither file nor Conversion Record.

Each committed output carries the immutable configuration snapshot, exact source
and output metrics, outcome, resize flag, and optional HDR-to-SDR downgrade. The
history layer never rereads mutable preferences.

## Preferences and Sync

Keep existing Quality keys and add:

| Key | Type | Default |
| --- | --- | --- |
| `imageConversion.mode` | String | `quality` |
| `imageConversion.targetSize.targetFormat` | String | `jpeg` |
| `imageConversion.targetSize.bytes` | Int | `1_000_000` |
| `imageConversion.targetSize.unit` | String | `mb` |
| `imageConversion.targetSize.allowResize` | Bool | `false` |
| `imageConversion.transparencyBackgroundHex` | String | `#FFFFFF` |

All are portable and join `SyncSettingsRegistry`. Window frame, split ratio,
selection, zoom, pan, navigation, preview and run state stay local. Invalid
imported mode, unit, target bytes, color, or format falls back independently in
the preferences facade.

The target is persisted as normalized integer bytes plus its presentation unit,
never as `Double`. The field uses decimal arithmetic and accepts positive values
with at most two fractional digits. Switching the unit converts only the
displayed number — the stored bytes never change on a unit switch; the display
may round to two fractional digits and the exact bytes are re-derived from the
text only when the user edits the field.

## SwiftData Migration

`ImageConversionRecord` remains one of the existing seven models. Existing
fields retain their names and types. Add only scalar/optional-scalar fields with
inline defaults:

| Field | Type/default |
| --- | --- |
| `modeRaw` | `String = "quality"` |
| `outcomeRaw` | `String = "qualityCompleted"` |
| `targetByteCount` | `Int64? = nil` |
| `sourceByteCount` | `Int64? = nil` |
| `outputByteCount` | `Int64? = nil` |
| `sourcePixelWidth/Height` | `Int? = nil` |
| `outputPixelWidth/Height` | `Int? = nil` |
| `resizeFallbackApplied` | `Bool = false` |
| `displayDowngradeRaw` | `String? = nil` |
| `firstFrameOnly` | `Bool = false` |

`outcomeRaw` V1 values are `qualityCompleted`, `targetReached`, and
`targetUnattainable`. `displayDowngradeRaw` supports only `hdrToSDR`.
`firstFrameOnly` records Quality mode's multi-frame first-frame conversion and
stays `false` for Target Size records. Existing `qualityPercent` remains the
selected Quality-mode value and is zero in Target Size records; mode-aware UI
renders it as not applicable.

Conversion Records represent files, so unsupported, failed, and cancelled items
do not create rows, and a target miss creates its `targetUnattainable` row only
when the user explicitly saves the Best-Effort artifact. An output later
deleted by the user remains a record with a missing-file presentation state.

History accepts a `CommittedOutput`. Insert, capacity trim, and one `save()` form
a transaction. On save failure it rolls back and leaves `revision` unchanged.
The committed file and its normal basket/clipboard outcome remain valid; the run
summary adds a history-warning count.

A frozen on-disk store produced by the pre-extension schema is a migration
fixture. The migration test opens it with the new seven-model schema, faults old
records, and verifies old values plus every new default. A new in-memory store
cannot prove this migration path.

## Verification

### Pure policy tests

- decimal target parsing, overflow, unit behavior and preference fallback;
- unit switching preserves the exact stored bytes and only converts/rounds the
  displayed number;
- non-monotonic candidate tables retain the highest-quality measured qualifier
  and smallest measured Best-Effort Result;
- Best-Effort stop reason is `qualityFloorReached` when resizing is off and
  `pixelFloorReached` when resizing is exhausted, and the inline Resize
  Fallback suggestion is offered only for the former;
- resize calculations clamp at 640, never create a zero edge, sample from the
  original, and stop at six levels/17 attempts;
- fingerprint and generation-token invalidation;
- per-item outcome to basket/history/clipboard policy.

### Real Image I/O tests

- outputs decode and successful final bytes are within the limit;
- impossible targets return a real oversized Best-Effort artifact that is not
  written to the output location until explicitly saved;
- JPEG composites the selected background;
- runtime-supported HEIC/AVIF round-trip alpha;
- Target Size removes ancillary metadata and retains orientation/color;
- HDR survives or records `hdrToSDR`;
- lossless pass-through must pass byte and metadata audit;
- multi-frame GIF and multi-page TIFF convert first-frame-only with the
  recorded fact in Quality mode and are rejected in Target Size; PDF is
  rejected in both modes;
- preview reuse adds zero encodes when fingerprints match;
- source/configuration changes force a new candidate.

### Writer, batch and persistence tests

- same-extension protection, repeated collisions, concurrent final-name claim,
  read-only destination, unsupported exclusive commit, staging cleanup and
  unchanged source;
- cancellation before and after the commit point;
- mixed success/Best-Effort/unsupported/encode/write outcomes, serial order,
  exact basket removal, and clipboard ordering;
- Best-Effort-only and failure-only runs leave the pasteboard unchanged and
  write no files;
- Save Anyway commits the retained artifact byte-identically with zero
  re-encodes and creates the record only after a successful commit; the
  retained artifact survives window hiding, is replaced by a newer candidate on
  retry, and is deleted on item removal and app exit;
- history transaction rollback/revision and frozen-store migration.

### Platform and performance gates

Run the same deployment-target-14 capability probe on real macOS 14 and 26. It
reports encoder availability, effective quality, alpha, metadata rewrite, GPS
removal, orientation/color, HDR downgrade, final decodability, and byte-limit
outcome. Current macOS 26 evidence is not accepted as a macOS 14 guarantee.

On the documented reference Mac:

- 12 MP Target preview p95: JPEG/HEIC no more than 5 seconds; AVIF no more than
  10 seconds;
- 48 MP incremental peak RSS below 1 GB;
- reused-candidate APFS commit below 250 ms;
- Quality mode performs one encode;
- Target Size performs no more than 17 copy/finalize attempts;
- cancellation responds no later than completion of the current finalize.

Calibration uses a redistribution-safe versioned corpus with photos, Chinese and
English UI text, line art, gradients, transparency, P3/HDR, noise, panoramas,
already-compressed images, and 48 MP stress inputs. Review happens at Fit, 100%,
and 200%. V1 uses one conservative floor per format, not content classification.

## Expected Code Shape

Prefer focused files instead of expanding the existing view and view model into
mega-types. Expected new components include:

- conversion configuration, outcome, progress and dimension value types;
- source preflight/capability cache;
- versioned target-size policy and search;
- deep Image I/O engine actor;
- candidate job/artifact store and startup janitor;
- atomic output writer;
- conversion sidebar, comparison workspace, synchronized image viewport and
  inspector views.

Expected modified seams include `ImageConversionViewModel`,
`ImageConversionSession`, `ImageConversionPreferences`, `SyncSettingsRegistry`,
`ImageConversionRecord`, `ImageConversionHistoryStore`,
`ImageConversionWindowController`, localization, and focused Image Conversion
tests. No dependency or new SwiftData model is added.
