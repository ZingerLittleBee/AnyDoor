# Translation — Design

Status: Draft (approved direction, pending spec review)
Date: 2026-06-22
Author: AnyDoor

## Overview

Add a **Translation** feature to AnyDoor: an Easydict-style floating panel that
translates text through several services **at once** and stacks each service's
result as its own card. The panel auto-detects the source language, shows
"Recognized as 〇〇", lets the user pick source/target languages (with a swap
button), speaks text aloud (TTS), copies results, and can be pinned open.

Three entry points, each a global hotkey:

1. **Open the translation window** (empty, focused, ready for input).
2. **Screenshot translate** — interactive region selection → Vision OCR → fill
   the input box → translate.
3. **Translate selection** — read the currently selected text in any app →
   fill → translate.

Translation works **out of the box with zero API keys**: Apple's on-device
Translation (macOS 15+), plus unofficial keyless Google and Bing/Microsoft
endpoints. Power users add **OpenAI-compatible LLM** services (Zhipu /
SiliconFlow / DeepSeek / OpenAI, …) with a base URL + model + key + prompt; LLM
output streams token-by-token.

The feature reuses AnyDoor's established idioms throughout: `BuiltinItem` +
`ActionProvider` entries (free panel rows, hotkey recording, conflict
detection, seeding), a `@MainActor @Observable` settings singleton backed by
UserDefaults (like `CaptureSettings`/`CommandPaletteService`), the existing
capture+OCR pipeline (`SelectionOverlayWindow` + `TextRecognizer`), a floating
`NSPanel` window controller (like `CommandPaletteWindowController` /
`ClipboardTextWindow`), and SwiftData for history.

## Goals

- One panel; **N services translate the same text concurrently**, results stacked
  as collapsible cards (loading / streaming / success / error per card).
- Zero-config defaults: **Apple** (macOS 15+), **Google free**, **Bing free**.
- User-added **OpenAI-compatible** LLM service instances (multiple), keys in
  Keychain, streaming output.
- Auto source-language detection ("Recognized as 〇〇") via `NLLanguageRecognizer`.
- Source/target language bar (Auto Detect ⇌ native language) with swap.
- **Enter triggers translation** (not on-type).
- TTS via `AVSpeechSynthesizer` (per-card + input), plus optional **auto-speak**
  of the translated text.
- Copy buttons (input + each result), following the existing pasteboard idiom.
- **Spotlight-style** floating window: takes key focus, Esc / click-outside
  dismiss, **pinnable** (stays open), remembers last size/position.
- Three global hotkeys: open window, screenshot translate, translate selection.
- **Settings → Translation** tab: native/target language, second target for
  same-language case, auto-speak, service management (enable/order/add/remove +
  per-service config), history retention.
- **Favorites + history** of translations, viewable inside the window.
- Portable settings join config sync/backup; **secrets and history do not**.

## Non-Goals (v1)

- Bespoke dictionary providers (e.g. iCIBA word-lookup API). The pluggable model
  leaves room; v1 ships Apple + Google + Bing + OpenAI-compatible only.
- Official keyed Google Cloud Translation / Azure Translator adapters (only the
  keyless free endpoints in v1; the protocol makes these trivial to add later).
- On-type / debounced translation (Enter-only in v1; the trigger is a single
  policy point, easy to make configurable later).
- Inline dictionary entries, phonetics, example sentences, conjugation tables.
- Translating rich text / documents / files (plain text only).
- Per-app or rule-based automatic translation.

## Product Decisions

| Decision | Choice |
|---|---|
| Layout | Easydict-style: input → "Recognized as" → source/target+swap → stacked service cards |
| Service model | Pluggable `TranslationProvider`; LLM-first |
| Default (keyless) services | Apple (macOS 15+), Google free endpoint, Bing/MS free endpoint |
| User services | OpenAI-compatible LLM instances (base URL + model + key + prompt), multiple |
| Free Google/Bing | Unofficial keyless endpoints (Easydict-style); risk isolated per adapter |
| Trigger | **Enter** (force); no on-type |
| Window | Spotlight-style floating `NSPanel`, key focus, Esc/click-out dismiss, **pinnable**, remembers frame |
| Result delivery | **Unified streaming** (`AsyncThrowingStream`): LLM streams; others yield once |
| Selected-text capture | **AX `kAXSelectedTextAttribute` first, clipboard ⌘C fallback** (restores pasteboard) |
| History storage | **SwiftData** new `@Model` (5th model in the container) |
| Secrets | New `TranslationKeychainStore` (SecItem); never in UserDefaults/backup |
| TTS | `AVSpeechSynthesizer` (AVFoundation) |
| Language detection | `NLLanguageRecognizer` (NaturalLanguage) |
| Extra features (v1) | Translate-selection hotkey, favorites+history, auto-speak |

## Architecture

```
  Hotkeys / panel rows                  Floating window
  ┌───────────────────────────┐         ┌────────────────────────────────┐
  │ TranslateProvider         │         │ TranslationWindowController     │
  │ ScreenshotTranslateProvider│──opens─▶│  NSPanel (.nonactivatingPanel,  │
  │ TranslateSelectionProvider │         │  key focus, Esc/click dismiss,  │
  │  (ActionProvider, @MainActor)        │  pin, remembers frame)          │
  └─────────────┬─────────────┘         │  hosts SwiftUI TranslationView  │
                │ fill text + request    └───────────────┬────────────────┘
                ▼                                         │ observes
        ┌────────────────────────────────────────────────▼─────────────┐
        │ TranslationCoordinator  (@MainActor @Observable)              │
        │  - enabled providers (ordered)                                │
        │  - detect source (LanguageDetector)                           │
        │  - fan out request → per-service AsyncThrowingStream          │
        │  - publishes [TranslationResult] (id, status, text, error)    │
        │  - cancels in-flight on new request                           │
        └───┬───────────────┬───────────────┬───────────────┬──────────┘
            ▼               ▼               ▼               ▼
   AppleTranslation   GoogleFree       BingFree        OpenAICompatible × N
   (.translationTask  (gtx endpoint)   (edge-auth)     (SSE streaming, key
    macOS 15+)                                          from Keychain)

  Support services (@MainActor unless noted):
   TranslationSettings (UserDefaults)   TranslationKeychainStore (SecItem)
   LanguageDetector (NL)                SpeechService (AVSpeechSynthesizer)
   SelectedTextReader (AX + clipboard)  TranslationHistoryStore (SwiftData)

  Reused: SelectionOverlayWindow + CaptureCoordinator + TextRecognizer (OCR),
          PanelStore / BuiltinPreferenceSeeder / HotkeyService, SyncSettingsRegistry,
          L10n + Localizable.xcstrings.
```

### Why a coordinator (not a provider per service in PanelStore)

The 3 `BuiltinItem` providers are thin entry points (open window / capture+OCR /
read selection). The actual translation fan-out is its own concern, owned by
`TranslationCoordinator` and consumed by the SwiftUI window. This keeps the
panel/hotkey layer decoupled from translation business logic, mirroring how
`CommandPaletteWindowController` and `ScheduledShutdownService` separate the
entry provider from the feature brain.

## Translation Provider Abstraction

```swift
enum TranslationServiceKind: String, Codable {
    case apple, googleFree, bingFree, openAICompatible
}

struct TranslationRequest: Sendable {
    var text: String
    var source: TranslationLanguage?   // nil = auto-detect
    var target: TranslationLanguage
}

enum TranslationChunk: Sendable {
    case detected(TranslationLanguage)  // optional: provider-reported source lang
    case delta(String)                  // incremental text (LLM streaming)
    case final(String)                  // full text (one-shot providers)
}

protocol TranslationProvider: Sendable {
    var id: String { get }              // stable per configured instance
    var kind: TranslationServiceKind { get }
    func translate(_ req: TranslationRequest) -> AsyncThrowingStream<TranslationChunk, Error>
}
```

- **One-shot providers** (Apple / Google / Bing) yield `.final` once (plus an
  optional `.detected`).
- **LLM providers** yield a stream of `.delta`s as SSE arrives, so cards fill in
  live. The coordinator accumulates deltas into the card's text.
- Errors throw into the stream → that card shows an error; **other cards are
  unaffected** (per-service isolation).

### Built-in services

- **AppleTranslationProvider** — wraps the macOS 15+ Translation framework. The
  framework is SwiftUI-`.translationTask`-centric, so the Apple card is driven by
  a `.translationTask` modifier hosted inside `TranslationView`, bridged back to a
  `.final` chunk. Gated `if #available(macOS 15, *)`; **hidden on macOS 14**.
- **GoogleFreeTranslationProvider** — unofficial keyless
  `translate.googleapis.com/translate_a/single?client=gtx&...` (the endpoint the
  Google Translate web UI uses; same as Easydict/translate-shell).
- **BingFreeTranslationProvider** — unofficial keyless flow: fetch an auth token
  from `edge.microsoft.com/translate/auth`, then call the Edge translator API.
- **OpenAICompatibleProvider** — configurable instance: `baseURL`, `model`,
  `apiKey` (Keychain), `promptTemplate` (with `{source}`/`{target}`/`{text}`
  placeholders). Calls `/chat/completions` with `stream: true`; parses SSE.

> **Risk:** the Google/Bing endpoints are unofficial and may rate-limit or change
> without notice. Each adapter is self-contained; failures degrade to a per-card
> error. We accept this as a maintenance cost (standard practice for this class
> of app).

## Entry Points & Hotkeys

Three `BuiltinItem` cases, each an `ActionProvider` registered in `AppDelegate`
and seeded by `BuiltinPreferenceSeeder` (initially unbound, default order in a
fresh slot):

- `.translate` → `TranslateProvider.run()` → `TranslationWindowController.toggle()`.
- `.screenshotTranslate` → region capture (reuse `CaptureCoordinator` /
  `SelectionOverlayWindow`) → `TextRecognizer.recognize()` → join lines → open
  window prefilled → translate.
- `.translateSelection` → `SelectedTextReader.read()` → open window prefilled →
  translate.

Hotkeys are recorded in the **Panel** settings tab like every other builtin
(`HotkeyRecorder`), participate in `entryUsingHotkey` conflict detection, and
flow through `rebuildHotkeySnapshots()` → `HotkeyService`. No new
`HotkeyAction` case is required — `.runBuiltin(itemKey)` already covers all three.

### SelectedTextReader

1. Try Accessibility: focused element's `kAXSelectedTextAttribute` (the app
   already holds the Accessibility permission for the event tap).
2. Fallback: synthesize ⌘C, read `NSPasteboard.general`, then **restore** the
   previous pasteboard contents. Mark the self-write so `ClipboardWatcher`
   doesn't record it (existing `noteSelfWrite` idiom).

## Translation Window

`TranslationWindowController` (@MainActor) owns a floating `NSPanel`
(`[.borderless, .nonactivatingPanel]`, clear background, `.floating` level,
`hasShadow`, `collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]`,
`isReleasedWhenClosed = false`, `isRestorable = false`). It hosts an
`NSHostingView` of `TranslationView` using the project's measure-once-then-detach
sizing pattern (avoids window-resize recursion). Key focus: from `.accessory`
policy, `NSApp.activate(ignoringOtherApps: true)` then `makeKeyAndOrderFront`.

Lifecycle:
- **Dismiss:** Esc key monitor + click-outside monitor → `orderOut`. When
  **pinned**, both dismissals are disabled; only the pin toggle / explicit close
  hides it.
- **Frame memory:** persist last frame to UserDefaults; restore on show
  (clamped to a connected screen).
- **Re-entry:** toggling the open hotkey while visible hides it; the
  screenshot/selection entries always show + prefill.

## UI (TranslationView)

SwiftUI, mapped to the mockup:

- **Toolbar (top):** pin (toggle stay-open) · favorites/history · screenshot
  translate · settings gear (opens the Translation settings tab).
- **Input area:** `TextEditor`; "Recognized as 〇〇" chip (live detection);
  speaker (speak source) + copy. **Enter** translates (Shift+Enter = newline).
- **Language bar:** source dropdown (Auto Detect + language list) ⇌ swap ⇌ target
  dropdown (defaults to the native language).
- **Results:** scrollable list of `TranslationServiceCard`, one per enabled
  service, in the user's configured order. Each card: service icon + name,
  collapse chevron (remembers expanded state), translated text, speaker, copy,
  and loading / streaming / error states. The **Apple** card hosts the
  `.translationTask` modifier (macOS 15+ only).
- **Auto-speak:** when enabled, speak the first/primary card's result on
  completion.

## Settings → Translation tab

New tab in `SettingsView`; `TranslationSettingsView` bound to
`TranslationSettings.shared`:

- **Native / primary target language** (default: follow system).
- **When source == target, translate to** (second target; default: English).
- **Auto-speak translated text** (toggle).
- **Services list:** enable/disable, drag to reorder, add/remove instances. Each
  OpenAI-compatible instance has a config sheet: display name, base URL, model,
  API key (Keychain), prompt template, and a **Test** button. Apple/Google/Bing
  are fixed entries that can be enabled/disabled/reordered (Apple row hidden on
  macOS 14).
- **History:** retention count; clear history.

The three hotkeys live in the **Panel** tab with the other builtins (a gear in
the translation window deep-links to this Translation tab).

## Data Model & Persistence

### Settings (UserDefaults) — `TranslationSettings`

`@MainActor @Observable final class` following the `CaptureSettings` idiom:
`static let shared`, static string keys, `private(set)` properties, explicit
setters that write both memory and `UserDefaults`, `reloadFromDefaults()` for
config import. Stores: target language code, second-target code, auto-speak bool,
and a `[TranslationServiceConfig]` encoded as JSON (a string), where
`TranslationServiceConfig` holds `id`, `kind`, `displayName`, `enabled`, `order`,
`iconName`, and (for `openAICompatible`) `baseURL`, `model`, `promptTemplate`.
**API keys are NOT in this struct** — they live in Keychain, keyed by `id`.

### Secrets — `TranslationKeychainStore`

New thin `SecItem` wrapper (`kSecClassGenericPassword`, service
`dev.bybee.AnyDoor.translation`, account = service instance `id`). `set/get/delete`
for the API key string. This is the **first Keychain usage in the codebase**.
Keys are never serialized to UserDefaults or backups.

### History/Favorites — SwiftData `TranslationRecord`

New `@Model`, the **5th** model in the container (currently exactly 4). Update
the `ModelContainer` schema in `AppDelegate` and the model list in `CLAUDE.md`.
Follow the migration rules: scalar fields with **inline defaults**, no
array/Codable stored columns (store any list as a JSON `String?` behind a
computed facade, per the `ClipboardHistoryItem.tagIDsJSON` precedent).

Fields (all scalar, defaulted): `id`, `createdAt`, `sourceText`,
`translatedText`, `sourceLangCode`, `targetLangCode`, `serviceID`,
`isFavorite: Bool = false`. `TranslationHistoryStore` provides CRUD, retention
trimming, and favorite toggling. History is **machine-local** (not synced),
consistent with clipboard history.

### Languages — `TranslationLanguage`

A curated value type wrapping a BCP-47 code with a localized display name and
mappings to: `NLLanguage` (detection), `Locale.Language` (Apple Translation),
and per-service codes (Google/Bing). Ship ~25 common languages plus "Auto
Detect" for the source slot.

## Config Sync / Backup

Register the portable translation keys in `SyncSettingsRegistry`: target
language, second target, auto-speak, and the **service config JSON minus keys**.
Add `TranslationSettings.reloadFromDefaults()` to the post-import
`reconcileAfterImport` path so changes apply without relaunch. **Excluded from
sync:** API keys (Keychain) and history/favorites (machine-local).

## Localization

UI strings are Chinese (the app's UI language) and go through `L10n` /
`LocalizedText`; add `L10n.Key` cases plus `Localizable.xcstrings` entries (en +
zh-Hans). Example: `translation.recognizedAs = "识别为 %@"`,
`translation.sourceAuto = "自动检测"`, `settings.tab.translation = "翻译"`.

## Risks & Mitigations

- **Apple Translation is SwiftUI/`.translationTask`-centric & macOS 15+** —
  drive its card via the modifier in `TranslationView`; gate availability; hide
  on macOS 14. If programmatic batch translation proves too constrained, the
  Apple card simply stays SwiftUI-modifier-driven (the rest of the pipeline is
  unaffected because it's `.final`-only).
- **Unofficial Google/Bing endpoints** — isolated per adapter; per-card error on
  failure; no impact on other services.
- **AX selected text not universal** (some Electron/terminal apps) — clipboard
  ⌘C fallback with pasteboard restore.
- **First Keychain usage** — small, self-contained wrapper; covered by tests with
  a dedicated service name.
- **5th SwiftData model** — follow scalar-default migration rules; verify a clean
  launch against an existing store (lightweight migration).
- **CGEvent tap budget** — translation/network work never runs in the tap
  callback; the providers only fire after the window/coordinator dispatch
  (existing constraint, just reaffirmed).

## File-Level Impact

**New:**
- `Models/TranslationLanguage.swift`, `Models/TranslationServiceConfig.swift`,
  `Models/TranslationRecord.swift` (SwiftData), `Models/TranslationResult.swift`
  (+ `TranslationRequest`/`TranslationChunk` value types).
- `Services/Translation/TranslationProvider.swift` (protocol),
  `AppleTranslationProvider.swift`, `GoogleFreeTranslationProvider.swift`,
  `BingFreeTranslationProvider.swift`, `OpenAICompatibleProvider.swift`,
  `TranslationCoordinator.swift`, `TranslationSettings.swift`,
  `TranslationKeychainStore.swift`, `LanguageDetector.swift`,
  `SpeechService.swift`, `SelectedTextReader.swift`,
  `TranslationHistoryStore.swift`.
- `Services/Providers/TranslateProvider.swift`,
  `ScreenshotTranslateProvider.swift`, `TranslateSelectionProvider.swift`.
- `Views/Translation/TranslationWindowController.swift`, `TranslationView.swift`,
  `TranslationServiceCard.swift`, `LanguageBar.swift`, plus
  `Views/TranslationSettingsView.swift`.
- Tests under `Tests/AnyDoorTests/` (see below).

**Changed:**
- `Models/BuiltinItem.swift` (3 cases + metadata), `AppDelegate.swift` (register
  3 providers; add `TranslationRecord` to the schema),
  `BuiltinPreferenceSeeder.swift` (seed 3 items),
  `Views/SettingsView.swift` (add Translation tab),
  `Services/SyncSettingsRegistry.swift` (whitelist portable keys),
  `BackupService.reconcileAfterImport` (reload `TranslationSettings`),
  `Utilities/L10n.swift` + `Resources/Localizable.xcstrings`, `CLAUDE.md`
  (document the subsystem + the 5th model), `Package.swift` (only if a dependency
  is needed — expected **none**; AVFoundation/NaturalLanguage/Translation/Vision
  are system frameworks).

## Testing Strategy

- **Pure/unit:** language detection mapping, `TranslationServiceConfig`
  encode/decode, prompt-template substitution, SSE delta accumulation,
  same-language→second-target selection, settings persistence (injected
  UserDefaults suite, `CaptureSettingsTests` pattern), Keychain wrapper
  round-trip (dedicated service name), history store CRUD + retention (in-memory
  `ModelConfiguration`).
- **Provider adapters:** behind a mockable HTTP boundary (the `RatesBackend`
  protocol pattern) so Google/Bing/OpenAI request building + response parsing are
  tested without network; injected fixtures.
- **Coordinator:** fan-out + cancel-in-flight + per-card isolation with fake
  providers (one streaming, one erroring, one one-shot).
- **Selection/OCR flows:** verify text routing into the coordinator (the capture
  overlay itself is exercised by existing capture tests).

## Open Questions

None blocking. Deferred (post-v1): official keyed Google/Azure adapters,
bespoke dictionary providers, configurable trigger mode, rich-text translation.
