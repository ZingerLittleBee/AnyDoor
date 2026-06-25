# Apple Translation Card — Language-Pack Download Gate

## Problem

In the translation window, the Apple on-device translation card
(`AppleTranslationCard`) only appears after a translate run, and when the
required on-device language pack is missing, pressing Enter silently presents the
system download sheet from another process (stealing focus, risking panel
dismissal). There is no in-card affordance telling the user a download is needed.

## Goal

When the language pack for the relevant pair is **not installed**:

1. The Apple card is **always visible** (even with empty input), rendered in a
   **collapsed** state with a **download button** in its header.
2. The collapse is **not expandable** — tapping the header or the download button
   triggers the system download sheet instead of expanding.
3. Pressing Enter does **not** auto-translate (and therefore no longer
   auto-presents the download sheet). The download happens only on explicit tap.

When the language pack **is installed**: existing behavior is unchanged (card
appears after a run, is expandable, shows the translation, auto-speak, history).

## Availability detection

Reuse Apple's `LanguageAvailability` (already used in both files). Relevant pair:

- Source known (selected or detected) → `source → effectiveTarget`.
- Source unknown (empty/idle input) → configured `secondTarget → target` (the same
  representative direction the settings download button uses). Assets are
  per-language, so one direction is enough.

Status mapping: `.installed` → ready; `.supported` → needs download;
`.unsupported` → not offered.

Re-evaluate on appear, on language/config change, and after a download completes.

## Approach: shared availability model (Approach B)

Extract a shared `@MainActor @Observable` model from the existing private
`AppleDownloadModel` (in `AppleLanguageDownloadButton.swift`) into its own file,
consumed by **both** the settings download button and the Apple card.

### New file: `Sources/AnyDoor/Views/Translation/AppleLanguagePackModel.swift`

- `@available(macOS 15, *) @MainActor @Observable final class AppleLanguagePackModel`
  - `enum Phase { case checking, needsDownload, downloading, installed, unsupported, failed }`
    (renamed from the current `.idle`/`.done` to read clearly for both consumers).
  - `private(set) var phase`, `private(set) var configuration: TranslationSession.Configuration?`
  - `struct LanguagePair { source; target }`
  - `func evaluate(pair:) async`, `func startDownload()`,
    `func didFinishPreparing(gen:) async`, `func fail(gen:)`, `currentGeneration`.
  - The `nonisolated func runApplePrepare(_:model:)` runner moves here too.
- Behavior is identical to today's `AppleDownloadModel`; only the type/phase names
  change and it gains a public home.

### `AppleLanguageDownloadButton.swift`

- Delete the private `AppleDownloadModel` + `runApplePrepare`; use the shared model.
- Update the `control` switch for the renamed phases (`needsDownload`/`installed`).
  UI output is unchanged.

### `AppleTranslationCard.swift`

The card gains a second, orthogonal dimension (availability) alongside the existing
run `status`. Outer `Group` stays always-mounted.

- Add `@State private var pack = AppleLanguagePackModel()`.
- `.task(id:)` keyed on the relevant pair codes drives `pack.evaluate(pair:)`.
- A second `.translationTask(pack.configuration)` drives `runApplePrepare` (the
  download path), guarded by `coordinator.beginSystemSheet()/endSystemSheet()` so
  the floating panel isn't dismissed while the system sheet holds focus. Only one
  of the two configurations (translate vs. prepare) is non-nil at a time.
- Render branches:
  - `.checking` + idle → render nothing (avoid flicker).
  - `.needsDownload` / `.downloading` / `.failed` → **collapsed download card**,
    always visible: header shows icon + name + a download button (spinner +
    "downloading" while in flight; orange retry on failure); body stays collapsed,
    not expandable; tapping the header or button calls `pack.startDownload()`.
  - `.unsupported` → render nothing.
  - `.installed` → existing behavior (render `card` only when `status != .idle`,
    expandable, shows translation).
- Translate gating: `refreshConfiguration()` (on `runToken` change) builds the
  translate configuration **only when `pack.phase == .installed`**; otherwise it
  does not translate. This removes the auto-popup of the download sheet.
- Post-download / race handling: `onChange(of: pack.phase)` — when it becomes
  `.installed` and `inputText` is non-empty and `status == .idle`, start the
  translation. This covers both auto-re-run after a successful download and the
  case where Enter was pressed while availability was still `.checking`.

Localization reuses the existing keys (`settingsTranslationDownloadLanguages`,
`...Downloading`, `...Failed`, etc.); no new catalog entries.

## Out of scope

- No change to non-Apple service cards.
- No change to the settings download button's visual design.
- `unsupported` stays a silent "no card" (not a surfaced message).
