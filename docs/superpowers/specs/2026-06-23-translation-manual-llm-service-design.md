# Manual (collapsed-by-default) LLM translation services

**Date:** 2026-06-23
**Status:** Approved design, pending implementation plan
**Scope:** Translation feature — `openAICompatible` (LLM) services only

## Problem

Every enabled translation service is translated automatically on each run:
`TranslationCoordinator.translate()` builds a provider for every enabled service
and immediately starts a task per provider. For LLM (`openAICompatible`)
services this means each Enter press spends tokens / latency on the LLM even when
the user only wanted the free engines (Google / Bing / Apple) that time.

We want a per-service **manual mode**: an LLM service can be configured to start
**collapsed and un-translated**. It does not auto-translate on a run; it
translates only when the user expands its card. Each new run resets it back to
collapsed/un-translated.

The existing per-card `collapsed` state is purely visual — the translation has
already run by the time the user collapses a card. It does not satisfy this
requirement, so a new mechanism is needed.

## Decisions (locked)

- **Applies to `openAICompatible` only.** Apple / Google / Bing are untouched.
  Apple in particular drives its own `.translationTask` on a separate code path
  (`AppleTranslationCard`), which this design deliberately does not modify.
- **Per-run reset.** Every `translate()` run (Enter) resets a manual service back
  to collapsed + un-translated. Expanding translates *that run's* captured
  request. Expanding does not "stick" across runs.
- **Within a run:** expand → translate once; collapse again keeps the cached
  result; re-expand shows the cached result without re-translating. A new run
  resets to deferred.

## Approach (chosen: coordinator-level deferral)

A manual service produces a real result card in a new `deferred` status with **no
task started**. Expanding the card asks the coordinator to translate just that
one service, reusing the run's captured request. This keeps `results` the single
source of truth for stream cards and guarantees no LLM call happens until the
user expands.

Rejected alternatives:
- *View-level lazy load* — manual services skipped from `results`, the view
  renders a standalone placeholder and inserts a result on expand. More divergent
  rendering paths and special-casing than the chosen approach.
- *Visual-only collapse* — start collapsed but still auto-translate. Does not
  satisfy "collapsed ⇒ no auto-translate".

## Components

### 1. Model — `TranslationServiceConfig`

- Add `var manualMode: Bool?`.
  - **Optional on purpose:** services are stored as a JSON string of
    `[TranslationServiceConfig]` in UserDefaults. Swift's synthesized `Decodable`
    throws on a missing key for a non-optional property, so existing stored
    configs (which lack the key) would fail to decode. Optional + `decodeIfPresent`
    (synthesized) decodes a missing key to `nil`. This mirrors the existing
    optional LLM fields (`baseURL` / `model` / `promptTemplate`).
  - Declared **after** `promptTemplate` so the memberwise initializer gives it a
    default and existing call sites (seeded defaults, editor, tests) still compile.
- Add a convenience: `var startsManual: Bool { kind == .openAICompatible && (manualMode ?? false) }`.
  Non-LLM kinds are never manual regardless of the stored flag.

### 2. Result model — `TranslationResult.Status`

- Add `case deferred`. A deferred result is `status: .deferred, text: ""`.
- The card renders `.deferred` as a collapsed, non-spinning state (distinct from
  `.idle`/`.loading`, which show the "translating" spinner).

### 3. Provider factory — `TranslationProviderFactory`

- Extract a single-config builder
  `makeStreamProvider(for config:, keychain:, session:) -> (any TranslationProvider)?`
  returning `nil` for `apple` and for incomplete `openAICompatible` (no key /
  missing baseURL / missing model). It ignores `manualMode` — an explicit single
  build always builds.
- `makeStreamProviders(settings:)` becomes
  `enabledServicesInOrder.filter { !$0.startsManual }.compactMap { makeStreamProvider(for: $0) }`
  so the automatic fan-out never runs a manual service.

### 4. Coordinator — `TranslationCoordinator`

- Store the current run's request: `private(set) var currentRequest: TranslationRequest?`
  (set in `translate()`), so `translateOne` reuses the exact text/target the
  sibling cards used.
- Inject a single-provider builder alongside the existing fan-out builder:
  `makeProvider: @MainActor (TranslationServiceConfig) -> (any TranslationProvider)?`,
  defaulting to `{ TranslationProviderFactory.makeStreamProvider(for: $0) }`. The
  existing `makeProviders` injection (auto fan-out) is retained.
- `translate()`:
  1. Bump `runToken`, trim text, guard non-empty (existing).
  2. `cancel()` + `updateDetection()` (existing).
  3. Build auto providers via `makeProviders()` inside `withKeychainPromptGuard`
     (existing).
  4. Build `results`: a `.deferred` entry for each enabled `startsManual` service,
     plus a `.idle` entry for each built auto provider. (Display order is driven
     by the view looking up results by id, so result array order is irrelevant.)
  5. Store `currentRequest`.
  6. Start one task per auto provider (existing pattern + runToken guard).
- `translateOne(serviceID:)`:
  1. Guard `currentRequest != nil`, the config exists, and the current result for
     that id is `.deferred` (ignore double-trigger / already running / done).
  2. Build the provider via `makeProvider(config)` inside `withKeychainPromptGuard`.
     If `nil` (key removed after save, etc.), set the result to `.failure` with
     `translationErrorMissingConfig`.
  3. Synchronously set the result to `.loading` (so the freshly-expanded card
     shows a spinner with no flicker), then start a task running the existing
     `run(provider:request:sourceText:)` with the stored request, keyed by id and
     guarded by the captured `runToken` (same supersede/cancel race handling as
     the fan-out).
- `run()` is reused unchanged: it sets `.loading → .streaming → .success/.failure`
  and records history via `recordSuccess` exactly like the fan-out path.
- `cancel()` needs no change: deferred entries have no task; an in-flight
  `translateOne` task lives in `tasks` and is cancelled by the next run.

### 5. Card — `TranslationServiceCard`

- Add an injected `onExpandDeferred: () -> Void` callback; the view binds it to
  `coordinator.translateOne(serviceID: config.id)`.
- Seed `collapsed` from `config.startsManual` (explicit init), so a manual card
  first appears collapsed.
- `.onChange(of: result.status)`: when it becomes `.deferred`, set `collapsed = true`.
  This re-collapses a manual card on every new run (the coordinator resets its
  result to `.deferred`). Non-manual services never enter `.deferred`, so their
  behavior is unchanged.
- In `toggleCollapsed()`: after expanding, if `result.status == .deferred` call
  `onExpandDeferred()`. (Both the header tap and the chevron route through this.)
- Header: when `result.status == .deferred`, show a small secondary hint
  (`translationManualCollapsedHint`) so the user understands the card is manual.
- `body(for:)` and `statusBadge`: add a `.deferred` case (no spinner; a hint or
  empty, since expanding immediately transitions to `.loading`).

### 6. Settings UI — `TranslationServiceConfigSheet`

- Add a `Toggle` bound to `draft.manualMode` (a `Binding<Bool>` over the optional,
  treating `nil` as `false`): label `settingsTranslationServiceManualMode`, with a
  footer `settingsTranslationServiceManualModeHint`. The sheet is only presented
  for `openAICompatible`, so no kind gating is required.
- `isSaveable` is unaffected (manual mode does not change runnability).

### 7. Localization

New keys (added to BOTH the `L10n.Key` enum AND `Localizable.xcstrings`, `en` +
`zh-Hans`):
- `settingsTranslationServiceManualMode` — toggle label.
- `settingsTranslationServiceManualModeHint` — footer explanation.
- `translationManualCollapsedHint` — the collapsed-card hint.

Reuse the existing `translationErrorMissingConfig` for a failed on-demand build.

## Data flow

```
Enter ─▶ translate()
          ├─ auto services  ─▶ .idle  ─▶ task ─▶ run() ─▶ .loading/.streaming/.success
          └─ manual services ─▶ .deferred  (no task)
                                   │
        user expands card ────────▶ translateOne(id)
                                   └─ build provider ─▶ .loading ─▶ run() ─▶ .success
Enter again ─▶ translate() resets manual services back to .deferred (+ card re-collapses)
```

## Error handling

- On-demand build returns `nil` (key removed, config became incomplete) →
  result `.failure` with `translationErrorMissingConfig`.
- Run failures flow through the existing `run()` catch → `.failure` +
  `translationErrorMessage(error)`.
- Superseding run cancels any in-flight `translateOne` task; the `runToken` guard
  drops stale writes.

## Testing

- **Model:** `manualMode` Codable round-trip; missing-key decode → `nil`;
  `startsManual` true only for `openAICompatible` with `manualMode == true`.
- **Factory:** `makeStreamProviders` excludes manual services; `makeStreamProvider(for:)`
  builds a single provider and returns `nil` for apple / incomplete configs.
- **Coordinator:** `translate()` creates `.deferred` results for manual services
  and starts no task for them; `translateOne` builds + runs a single provider and
  records success; a superseding `translate()` cancels an in-flight `translateOne`.

## Backward compatibility

- Existing stored configs decode with `manualMode == nil` ⇒ `startsManual == false`
  ⇒ unchanged auto-translate behavior.
- Non-LLM services and the Apple card are untouched.
- `manualMode` round-trips through `SyncSettingsRegistry` config backup like the
  rest of `TranslationServiceConfig` (it is part of the same JSON string).

## Out of scope

- Manual mode for Apple / Google / Bing.
- A global "manual by default for all LLM" preference.
- Persisting per-card expand/collapse across runs.
