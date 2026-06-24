# Translation history: merge one run into one card

**Date:** 2026-06-24
**Status:** Approved design, pending implementation plan
**Scope:** Translation feature — the in-window History + Favorites popover, plus the
record-writing path that feeds it.

## Problem

A single translation run fans the same input out to every enabled service and
writes one `TranslationRecord` per service (`recordSuccess` runs once per provider;
Apple records separately via `noteAppleSuccess`). The history popover then shows
each record as its own row, so one run (e.g. "good" → "很好" via Bing and "好的" via
Google) appears as several disconnected rows. The user wants one run shown as one
card that lists every service's result together.

The records carry no shared run identifier, so there is currently no way to know
which rows belong to the same run.

## Decisions (locked)

- **Card is expandable.** Collapsed: the original on top, then one line per service
  (`translation · serviceName`, truncated). Tap to expand: full original, then each
  service as `serviceName [copy]` + full translation (selectable), plus one
  "Re-translate" button. (Generalizes the single-result recall card already shipped.)
- **Favorite / delete operate on the whole card (the whole run).** The star toggles
  the favorite state of every record in the run together; the trash deletes every
  record in the run.
- **Copy is per service.** The expanded view gives each service its own copy button
  that copies only that service's translation.
- **Grouping is by an explicit `runID`.** Not a time-window heuristic.

## Components

### 1. Model — `TranslationRecord`

Add one scalar field:

```swift
var runID: String = ""
```

Inline-defaulted scalar `String`, so SwiftData lightweight migration backfills
existing rows to `""` with no transformable-column hazard (per the project's
migration rules). The `ModelContainer` schema is unchanged in membership — still the
same five `@Model` types; only this field is added. `runID` is added to the
memberwise `init` with a default so existing call sites compile.

History is already excluded from config backup, so `runID` does not affect backup.

### 2. Coordinator — `TranslationCoordinator`

- Store the current run's id alongside `currentRequest`:
  `private(set) var currentRunID: String = ""`.
- In `translate()`, after building `request`, set `currentRunID = UUID().uuidString`
  (a fresh id per run). Clear is unnecessary — a new run always overwrites it before
  any record is written.
- `recordSuccess(...)` and `noteAppleSuccess(...)` pass `runID: currentRunID` into
  `history.record(...)`.
- `translateOne(serviceID:)` needs no change: it routes through the same `run()` →
  `recordSuccess`, which reads `currentRunID`, so a manually-expanded LLM result
  joins its run's card automatically.
- A history card's "Re-translate" starts a brand-new `translate()`, which mints a
  new `runID` → a new card. (No special handling needed.)

### 3. Store — `TranslationHistoryStore`

- `record(...)` gains a `runID: String = ""` parameter (defaulted and placed so
  existing call sites — including the store's unit tests — keep compiling), written
  onto the new `TranslationRecord.runID`.
- Add run-group mutators used by the history view (the existing single-record
  `toggleFavorite(_:)` / `delete(_:)` are kept — the store's unit tests call them, so
  they are not dead code; the two new methods overload on `[TranslationRecord]`):
  - `setFavorite(_ records: [TranslationRecord], to value: Bool)` — sets every
    record's `isFavorite` to `value`, saves, bumps `revision`.
  - `delete(_ records: [TranslationRecord])` — deletes every record, saves, bumps
    `revision`.
- `recent(limit:)` and `favorites()` are unchanged (still return flat rows
  newest-first); grouping happens in the pure helper below. Because all records in a
  run share their favorite state (they are always toggled together), `favorites()`
  returns the complete set of rows for each favorited run, which then regroup into
  whole favorited cards.

### 4. Grouping — new `TranslationHistoryGrouping.swift` (pure, unit-testable)

```swift
struct TranslationRunGroup: Identifiable {
    let id: String                  // runID, or the record's own id when runID is empty
    let records: [TranslationRecord]
    var primary: TranslationRecord { records[0] }   // source text / languages / time anchor
    var isFavorite: Bool { records.allSatisfy(\.isFavorite) }
    var createdAt: Date { records.map(\.createdAt).max() ?? .distantPast }
}

func groupByRun(_ rows: [TranslationRecord]) -> [TranslationRunGroup]
```

`groupByRun` walks `rows` in the given order (the store returns newest-first),
bucketing by group key (`runID` when non-empty, else the record's own `id`), and
emits groups in first-encountered order — so groups stay newest-first. Within a
group, records are sorted by `createdAt` ascending (stable completion order). A
legacy row (`runID == ""`) forms its own single-record group, preserving today's
one-card-per-old-record behavior.

`primary` (used for the shared source text, language codes, and createdAt) is the
group's records sorted ascending, so `records[0]` is the earliest — its
`sourceText` / `sourceLangCode` / `targetLangCode` represent the run. (All records
in a real run share the same source text and direction.)

### 5. View — `TranslationHistoryView`

The list renders `groupByRun(currentRows())` instead of raw rows; the row builder
becomes a card builder over a `TranslationRunGroup`. `expandedID` keys on
`group.id`.

- **Collapsed card:** original (`primary.sourceText`, bold, `lineLimit(2)`); then for
  each record in the group a line showing its `translatedText` (`lineLimit(1)`) with
  the `serviceName` as a trailing caption; footer with relative time
  (`primary.createdAt`), the favorite star, and the delete control.
- **Expanded card:** `translationHistoryOriginalLabel` + full `primary.sourceText`
  (`.textSelection(.enabled)`); a divider; then for each record a block of
  `serviceName` + a copy button (copies that record's `translatedText`) followed by
  the full `translatedText` (`.textSelection(.enabled)`); then a
  `translationHistoryRetranslate` button.
- **Star:** filled when `group.isFavorite`; tapping calls
  `store.setFavorite(group.records, to: !group.isFavorite)`.
- **Trash:** `store.delete(group.records)`.
- **Re-translate:** restore `coordinator.source` / `coordinator.target` from
  `primary.sourceLangCode` / `primary.targetLangCode`, call
  `coordinator.prefill(primary.sourceText, autoTranslate: true)`, then `onSelect()`.
- **Copy** reuses the existing `copyTranslation` helper (NSPasteboard + noteSelfWrite
  + toast), called per record.
- Filter switch still resets `expandedID = nil`.

### 6. Localization

- Reuse `translationHistoryOriginalLabel` (原文), `translationCopy` (复制),
  `translationHistoryRetranslate` (重新翻译).
- The new design uses each `serviceName` as the per-result header, so
  `translationHistoryTranslatedLabel` (译文) — added in the previous feature — is no
  longer used. Remove it from BOTH `L10n.Key` and `Localizable.xcstrings` to avoid a
  dead key.

## Data flow

```
Enter ─▶ translate(): runToken++, currentRunID = UUID(), build request
          └─ each service success ─▶ recordSuccess ─▶ store.record(..., runID: currentRunID)
          (Apple) ─▶ noteAppleSuccess ─▶ store.record(..., runID: currentRunID)
          (manual expand) translateOne ─▶ run() ─▶ recordSuccess (same currentRunID)

History view: store.recent/favorites (flat, newest-first)
            ─▶ groupByRun ─▶ [TranslationRunGroup] (one card per run)
            tap card  ─▶ expand (recall, local, no network)
            copy      ─▶ per-record translation to clipboard + toast
            star/trash─▶ store.setFavorite/delete over group.records
            re-translate ─▶ coordinator.prefill(autoTranslate: true) ─▶ new run ─▶ new card
```

## Error handling

- Recall, expand, and copy never touch the network.
- Re-translate reuses the existing `translate()` path; failures surface on the main
  panel's service cards as today.
- A run where only some services succeeded simply yields a card with fewer rows
  (failures are not recorded — `recordSuccess` only writes non-empty successes).

## Backward compatibility

- Existing rows decode with `runID == ""` and each forms its own single-record card,
  identical to today's per-record display.
- Only `TranslationRecord` gains a field; the schema's `@Model` membership is
  unchanged. No store path or pinned-URL change.
- Removing `translationHistoryTranslatedLabel` only drops an unused key added in the
  prior (still-unreleased) feature.

## Testing

- **Pure / unit-tested:** `groupByRun` — same `runID` merges; empty `runID` rows each
  stand alone; group order is newest-first; within-group order is `createdAt`
  ascending; `isFavorite` is true only when every record is favorited; `createdAt` is
  the group max.
- **Build gate:** `swift build` clean (removing the L10n key must stay consistent
  across enum + catalog or the string-catalog plugin fails).
- **Existing suite stays green.**
- **Manual smoke:** a multi-service run shows one card listing every service; tap
  expands to full original + per-service translation + copy + re-translate; star
  favorites the whole run; trash deletes the whole run; the Favorites filter shows
  whole favorited cards; old (pre-`runID`) history still shows one card each.

## Out of scope

- Per-service favorite or delete.
- Backfilling `runID` onto old records by heuristic (they stay single-record cards).
- Showing failed services in the card.
- Changing the main translation panel's live result cards.
