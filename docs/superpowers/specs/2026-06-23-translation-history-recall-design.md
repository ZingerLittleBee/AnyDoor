# Translation history/favorites: recall instead of re-translate

**Date:** 2026-06-23
**Status:** Approved design, pending implementation plan
**Scope:** Translation feature — the in-window History + Favorites popover only

## Problem

Tapping a row in the History + Favorites popover currently **re-translates**:
`TranslationHistoryView.select(_:)` restores the record's source/target language
and calls `coordinator.prefill(record.sourceText, autoTranslate: true)`, which
re-runs a full fan-out translation and discards the result already stored on the
record.

This is wasteful and unfaithful:

- The record already holds `translatedText`; the tap throws it away and recomputes.
- LLM (`openAICompatible`) output is non-deterministic, so a re-run can differ from
  what the row displays — the history entry no longer reproduces itself.
- It contradicts the just-shipped manual-LLM (collapsed-by-default) feature, whose
  whole point is to avoid spending tokens unprompted; one tap fans out to every
  enabled service.
- History is written **per service result** (`recordSuccess` runs once per provider
  in `run()`), so a row represents one specific engine's output, but the re-run
  ignores `record.serviceID` and fans out to all currently enabled services.
- Recall requires the network — viewing a saved/favorited translation offline fails.

A history/favorites list is a log of past results to look back at and reuse. The
primary action should **recall** the stored result, not recompute it.

## Decisions (locked)

- **Tap = recall, in place.** Tapping a row expands it inline inside the popover to
  show the full original + full translation with a copy control. Pure local read —
  no network, no tokens. The main translation panel is not touched.
- **Re-translate is explicit and secondary.** The expanded detail area carries a
  "Re-translate" button that reproduces the old behavior (restore languages,
  prefill the input, auto-translate, dismiss the popover).
- **Primary gesture = expand/collapse.** Tapping a collapsed row expands it; tapping
  again (or tapping another row) collapses it. Single-open accordion.
- **Favorites behave identically.** The All and Favorites filters share the same row
  component and the same recall behavior.

## Approach (chosen: in-popover inline expand)

A new `expandedID: String?` view state drives a single-open accordion. The row's
primary tap toggles it instead of calling `select`. The expanded detail area reads
the record's already-stored fields (`sourceText` / `translatedText`) — nothing is
fetched or recomputed. The old re-translate logic moves verbatim behind a button.

Rejected alternative: *inject the stored translation into the main panel's service
cards.* The cards are keyed by a live `translate()` run (`coordinator.results`), so
injecting a synthetic past result is divergent, and a record whose service is no
longer enabled would have no card to render into. Inline expand is self-contained,
faithful, and works offline.

## Components

All changes live in `Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift`
unless noted.

### 1. Accordion state

- Add `@State private var expandedID: String?`.
- Add `private func toggle(_ id: String) { expandedID = (expandedID == id ? nil : id) }`.

### 2. Row (collapsed) — unchanged content, changed gesture

- Collapsed appearance is unchanged: source text (`lineLimit(2)`), translated text
  (`lineLimit(2)`), the `serviceName` + relative-time meta line, and the trailing
  favorite-star / delete controls.
- The row's primary `Button` action changes from `select(record)` to
  `toggle(record.id)`.
- The favorite-star and delete controls keep calling
  `store.toggleFavorite` / `store.delete` unchanged.

### 3. Row (expanded) — recall detail

When `expandedID == record.id`, render a detail section below the collapsed row:

- A caption `translationHistoryOriginalLabel` ("原文" / "Original") followed by the
  full `record.sourceText`, not line-limited, with `.textSelection(.enabled)`.
- A caption `translationHistoryTranslatedLabel` ("译文" / "Translation") followed by
  the full `record.translatedText`, not line-limited, with `.textSelection(.enabled)`,
  and a trailing **copy** button.
- A **re-translate** button.

### 4. Copy button

- Label/icon reuse `translationCopy`.
- Writes `record.translatedText` to `NSPasteboard.general` (`clearContents()` +
  `setString(_:forType:.string)`), then calls
  `ClipboardWatcher.shared?.noteSelfWrite(changeCount:)` (so AnyDoor's own clipboard
  history ignores the write, matching `TranslationView.copy`), then shows
  `ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))`.
- Pure local; no network.

### 5. Re-translate button

- Label reuses the new `translationHistoryRetranslate`.
- Performs exactly what `select(_:)` does today:
  1. `coordinator.source = TranslationLanguage.named(record.sourceLangCode)`
  2. `if let target = TranslationLanguage.named(record.targetLangCode) { coordinator.target = target }`
  3. `coordinator.prefill(record.sourceText, autoTranslate: true)`
  4. `onSelect()` (dismiss the popover)
- The old `select(_:)` method is removed; its body becomes this button's action.

### 6. Localization

Three new keys, added to BOTH the `L10n.Key` enum (`Sources/AnyDoor/Utilities/L10n.swift`)
AND `Sources/AnyDoor/Resources/Localizable.xcstrings` (`en` + `zh-Hans`):

- `translationHistoryRetranslate` — "Re-translate" / "重新翻译"
- `translationHistoryOriginalLabel` — "Original" / "原文"
- `translationHistoryTranslatedLabel` — "Translation" / "译文"

Reuse the existing `translationCopy` and `toastCopiedToClipboard`.

## Data flow

```
tap row           ─▶ toggle(expandedID)                      (no network, no tokens)
  copy button     ─▶ NSPasteboard write + noteSelfWrite + toast   (recall, local)
  re-translate    ─▶ restore source/target
                     ─▶ coordinator.prefill(sourceText, autoTranslate: true)
                     ─▶ onSelect()  (dismiss)                 (old behavior, explicit)
```

## Error handling

- Recall (expand) and copy never touch the network, so they cannot fail in a way
  the user must recover from.
- Re-translate reuses the existing `coordinator.translate()` path; failures surface
  on the main panel's service cards exactly as they do today.
- A record whose `serviceID` points at a since-removed service still recalls its
  stored text fine; re-translate fans out to the currently enabled services (same as
  today's behavior).

## Testing

This is a self-contained SwiftUI view change: a collapse/expand accordion, a local
copy, and the relocation of already-tested logic (`coordinator.prefill`) behind a
button. The project's test suites (XCTest + swift-testing) cover logic units, not
SwiftUI tap/expand interactions, and forcing a UI test here would add a brittle,
low-value test. No new unit test is warranted.

Verification:

- `swift build` succeeds (new `L10n.Key` cases require matching `.xcstrings`
  entries, or the string-catalog build-tool plugin fails the build).
- The full existing test suite stays green (baseline unchanged; no logic altered).
- Manual smoke test:
  - Tapping a history row expands it and shows the full original + translation
    without any network activity or new service-card spinner.
  - The copy button puts the stored translation on the clipboard and shows the
    success toast.
  - The re-translate button refills the input, restores the language direction,
    runs a fresh translation, and dismisses the popover.
  - The same behavior holds under the Favorites filter.

## Backward compatibility

- No model, store, or persistence change — `TranslationRecord` and
  `TranslationHistoryStore` are untouched, so existing history/favorites rows render
  and behave under the new interaction without migration.
- The re-translate path is byte-for-byte the old tap behavior, just moved behind an
  explicit button.

## Out of scope

- Injecting recalled results into the main translation panel's service cards.
- Editing a record's text before re-translating.
- Re-translating with the record's original single service instead of the current
  fan-out.
- Copying the original (source) text via a dedicated button — `.textSelection`
  already allows manual selection of either field.
