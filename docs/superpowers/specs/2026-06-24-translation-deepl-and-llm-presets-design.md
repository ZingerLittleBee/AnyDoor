# Translation: add DeepL backend + LLM provider presets

Date: 2026-06-24
Status: Approved (design)

## Summary

AnyDoor's translation panel currently fans one input out to four service kinds:
`apple` (on-device card), `googleFree`, `bingFree` (free web endpoints), and
`openAICompatible` (a generic user-added LLM). The LLM kind already covers the
whole OpenAI-compatible ecosystem, but two gaps remain versus comparable tools
(Bob / Easydict / Pot / Immersive Translate):

1. **No dedicated machine-translation API.** DeepL is the category standard and
   cannot be reached through `openAICompatible` (it uses its own auth format).
2. **High setup friction for LLMs.** Adding any LLM means hand-typing the base
   URL, model id, and prompt. Peer tools offer "pick a provider, enter a key".

This design adds:

- **A `deepl` provider kind** (official DeepL API + optional self-hosted DeepLX
  endpoint), added through the same flow as LLMs.
- **A preset catalog** that pre-fills a new service's connection fields so the
  user only supplies an API key.
- **A small `extraBodyJSON` field** on the OpenAI-compatible config so presets
  can disable a model's "thinking" mode (needed for DeepSeek's current cheap
  model) and pass other per-provider request options.

### Goals

- Add DeepL (official + DeepLX) as a first-class fan-out service.
- One-click "add by provider" for the common LLM backends, key-only setup.
- Zero SwiftData migration; no change to the four `@Model` types.
- Keep the existing manual/streaming/history/auto-speak behavior intact.

### Non-goals (backlog)

- Chinese dedicated MT APIs with bespoke HMAC signing (Tencent / Volcengine /
  Baidu / Youdao / Caiyun) — each is its own provider; defer.
- Official paid cloud translation (Google Cloud Translate / Azure Translator).
- Anthropic Claude / Gemini *native* (non-OpenAI) request formats.
- An automatic cross-engine fallback chain.
- A plugin runtime (Bob/Pot style). Presets are a static in-app catalog.

## Verified backend reference

All values below were verified against primary/official docs (June 2026) and
adversarially re-checked. They are encoded as constants in the preset catalog
and the DeepL provider; treat this section as the source of truth for those
constants.

### DeepL (one-shot JSON, NOT streaming)

Official API:

- Hosts: `https://api-free.deepl.com` (Free) and `https://api.deepl.com` (Pro).
  Selected by the auth key suffix: a key ending in `:fx` is a Free key → use the
  Free host; otherwise use the Pro host. `key.hasSuffix(":fx") ? free : pro`.
- Endpoint: `POST {host}/v2/translate`, `Content-Type: application/json`.
- Auth header: `Authorization: DeepL-Auth-Key <rawKey>` (the literal scheme word
  `DeepL-Auth-Key`, a space, then the raw key including any `:fx`). **Not Bearer.**
- Request body: `{"text": ["..."], "target_lang": "ZH-HANS", "source_lang": "EN"}`.
  `text` is an array (we send a one-element array); `source_lang` omitted →
  auto-detect. We do not send `formality` (it errors for ZH/EN targets).
- Response: `{"translations": [{"detected_source_language": "EN", "text": "..."}]}`.
  Read `translations[0].text` and `translations[0].detected_source_language`.
- Errors: `403` auth/host mismatch, `456` quota exhausted (hard stop; Free =
  500k chars/month), `429`/`5xx`/`529` transient (retryable), `400` bad
  parameter (e.g. invalid lang code). Surface backend message where present.

DeepLX (unofficial proxy; user supplies their own endpoint):

- Endpoint: `POST {baseURL}/translate` (the app appends `/translate`).
- Request body: `{"text": "...", "source_lang": "auto", "target_lang": "ZH"}`.
  Note `text` is a **single string** here, not an array; `source_lang` may be
  `"auto"` or omitted.
- Response: `{"code": 200, "data": "...", "alternatives": [...], "source_lang":
  "EN", "target_lang": "ZH", "method": "Free"}`. Read `data`; treat `code != 200`
  as an error.
- Auth: none by default. If the operator started DeepLX with a token, send it as
  `Authorization: Bearer <token>`. Conventional self-host port is `1188` (part of
  the user-supplied base URL; not hardcoded).
- Caveats: unofficial, may break or get the host IP-banned; degrade gracefully on
  timeouts / `429` / `5xx`. We never ship a hardcoded shared public endpoint.

### DeepL language codes

The mapping is mode- and direction-dependent:

| App catalog code | Official `target_lang` | Official `source_lang` | DeepLX `target_lang` | DeepLX `source_lang` |
|---|---|---|---|---|
| `zh-Hans` | `ZH-HANS` | `ZH` | `ZH` | `ZH` |
| `zh-Hant` | `ZH-HANT` | `ZH` | `ZH` | `ZH` |
| `en` | `EN-US` | `EN` | `EN` | `EN` |
| other (e.g. `ja`, `fr`) | uppercased base (`JA`, `FR`) | uppercased base | uppercased base | uppercased base |
| nil source | — | omitted (auto) | — | `auto`/omitted |

Detected-source reverse map (from a DeepL response code back to the catalog):
`EN → en`, `ZH → zh-Hans` (default to Simplified; DeepL detection does not
distinguish Hans/Hant), otherwise lowercase the code and match the catalog.

### LLM presets (all OpenAI-compatible, Bearer auth, SSE streaming)

| Preset id | Display | baseURL | Default model | Notes |
|---|---|---|---|---|
| `openai` | OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` | reference impl |
| `deepseek` | DeepSeek | `https://api.deepseek.com/v1` | `deepseek-v4-flash` | thinking ON by default → preset sets `extraBodyJSON` `{"thinking":{"type":"disabled"}}` |
| `dashscope` | 通义千问 (Qwen) | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | `qwen-plus` | international endpoint; Beijing key needs `https://dashscope.aliyuncs.com/compatible-mode/v1` (user edits) |
| `gemini` | Gemini | `https://generativelanguage.googleapis.com/v1beta/openai/` | `gemini-2.5-flash-lite` | trailing slash + `/v1beta/openai/` path is required |
| `moonshot` | Kimi (Moonshot) | `https://api.moonshot.ai/v1` | `kimi-k2.6` | `.cn` host exists for China-region keys |
| `zhipu` | 智谱 GLM | `https://open.bigmodel.cn/api/paas/v4` | `glm-4.7-flash` | path is `/api/paas/v4`, must NOT force-append `/v1` |
| `openrouter` | OpenRouter | `https://openrouter.ai/api/v1` | `google/gemini-2.5-flash-lite` | model ids require a `provider/` prefix |
| `ollama` | Ollama (本地) | `http://localhost:11434/v1/` | `qwen3:4b` | local; key required-but-ignored, fill any non-empty string |

`OpenAICompatibleProvider.buildRequest` already trims a trailing slash and
appends `/chat/completions` with no forced `/v1`, so every base URL above
resolves correctly with no change to the URL-building logic. The request body
uses a single `role: user` message, so providers that reject a `system` role are
unaffected.

## Architecture

### 1. `deepl` provider kind

- Add `case deepl` to `TranslationServiceKind`.
- New `DeepLProvider: TranslationProvider` (`kind == .deepl`). Like Google/Bing
  it is one-shot: it performs one async `POST`, then yields a `.detected` chunk
  (mapped source language) followed by a single `.final` chunk, or finishes
  throwing. It does not stream deltas. It builds its own `AsyncThrowingStream`
  (the static `.single` helper can't run the network call).
- Mode selected by `config.baseURL`:
  - empty/nil → **official**: pick host by `:fx` suffix on the keychain key;
    `Authorization: DeepL-Auth-Key`; array `text` body; parse `translations[0]`.
  - non-empty → **DeepLX**: `POST {baseURL}/translate`; string `text` body;
    optional `Authorization: Bearer <token>` when the keychain value is
    non-empty; parse `data`.
- Secret storage reuses `TranslationKeychainStore` keyed by `config.id`: the one
  slot holds the DeepL auth key (official, required) or the DeepLX token
  (optional). No new secret store.
- `TranslationProviderFactory.makeStreamProvider` gains a `.deepl` branch:
  - official: return nil when no key (mirrors `openAICompatible`'s "incomplete →
    skip silently").
  - DeepLX: return a provider whenever `baseURL` is a valid http(s) URL (token
    optional).

### 2. `DeepLLanguage` (pure, testable mapping)

New file `Services/Translation/DeepLLanguage.swift`, a small enum/namespace of
pure functions so the code table above is unit-tested without a network or UI:

- `targetCode(_ lang: TranslationLanguage, deeplx: Bool) -> String`
- `sourceCode(_ lang: TranslationLanguage?, deeplx: Bool) -> String?`  (nil →
  omit for auto-detect)
- `language(fromDetected code: String) -> TranslationLanguage?`

This keeps `TranslationLanguage.serviceCode(for:)` untouched (its single-code,
direction-agnostic shape does not fit DeepL's source/target split).

### 3. Preset catalog

New file `Models/Translation/TranslationServicePreset.swift`:

```swift
struct TranslationServicePreset: Identifiable, Sendable {
    let id: String              // e.g. "deepseek", "deepl", "custom"
    let displayName: String
    let iconName: String        // SF Symbol
    let kind: TranslationServiceKind
    let baseURL: String?
    let model: String?
    let promptTemplate: String? // nil → defaultPromptTemplate
    let extraBodyJSON: String?  // nil → none
    static let catalog: [TranslationServicePreset]   // DeepL, the 8 LLMs, custom
}
```

`catalog` order: DeepL first, then the eight LLM presets, then a `custom`
sentinel (blank `openAICompatible`, current behavior). Building a draft
`TranslationServiceConfig` from a preset assigns a fresh `UUID` id and
`order = settings.services.count`.

### 4. `extraBodyJSON` on the OpenAI-compatible config (decision: adopted)

- Add `var extraBodyJSON: String?` to `TranslationServiceConfig` (Codable; this
  type is JSON in UserDefaults, **not** a SwiftData `@Model`, so an optional
  field decodes to nil for legacy stored services — no migration).
- `OpenAICompatibleProvider.buildRequest`: after composing the base body
  (`model` / `stream` / `messages`), if `extraBodyJSON` parses to a JSON object,
  shallow-merge its top-level keys into the body (the explicit base keys win on
  conflict). Invalid/empty JSON is ignored (no throw) so a bad value degrades to
  the plain request instead of breaking translation.
- Only the DeepSeek preset sets it initially
  (`{"thinking":{"type":"disabled"}}`). The field is editable in the LLM editor
  (advanced) so power users can add their own options.

### 5. Editor becomes kind-aware

`TranslationServiceConfigSheet` (and the `serviceRow` controls) branch on
`draft.kind`:

- `.openAICompatible`: unchanged fields (name / baseURL / model / key / prompt /
  manualMode), plus an optional advanced "extra body (JSON)" field.
- `.deepl`: name + API key, then a collapsible **Advanced (DeepLX)** disclosure
  with an optional self-host base URL and optional token. No model / prompt /
  manualMode. Footer explains official-vs-DeepLX.
- `isSaveable` per kind:
  - `.openAICompatible`: name + valid base URL + model + key (current rule).
  - `.deepl`: name AND (key present **or** a valid DeepLX base URL).
- The **Test** button runs `DeepLProvider` for `.deepl`, `OpenAICompatibleProvider`
  otherwise.
- `serviceRow`'s Edit/Remove buttons show for `.deepl` and `.openAICompatible`;
  Apple/Google/Bing stay non-editable built-ins.

### 6. Add-service flow

The single "+ add service" button becomes a menu listing the preset catalog
(DeepL, the LLMs, then "自定义"). Selecting an entry builds a pre-filled draft
from that preset and opens the kind-aware editor; the user enters a key and
saves. "自定义" opens a blank `openAICompatible` draft (today's behavior). No
seeding/migration is needed because everything beyond the three free built-ins is
explicitly user-added.

## Data flow

Unchanged from today: `TranslationCoordinator.translate()` builds providers via
`TranslationProviderFactory.makeStreamProviders`, fans the request out, and each
provider streams `TranslationChunk`s into a `TranslationResult` card. DeepL slots
in as another fan-out provider that yields `.detected` + `.final`. History,
run-grouping, favorites, and auto-speak are untouched.

## Error handling

- DeepL official: map `403 → "auth/host"`, `456 → "quota exhausted"`,
  `429/5xx/529 → transient`, surface the backend's error body message when
  present (DeepL returns `{"message": "..."}`); otherwise fall back to the status
  code. Reuse the existing `TranslationProviderError` cases (`apiError`,
  `badResponse`, `network`, `decodeFailed`, `emptyResponse`).
- DeepLX: `code != 200` → `apiError` with the response `message` when present.
- `extraBodyJSON` parse failure is swallowed (request proceeds without it).

## Testing

- `DeepLLanguage`: target/source code mapping for both modes (ZH-HANS/ZH-HANT/
  EN-US variants vs ZH/EN base), nil source → omit, detected-code reverse map.
- `DeepLProvider`: request construction (host selection by `:fx`, header, array
  vs string `text`, auth styles) and response parsing (`translations[0].text` vs
  `data`, `code != 200` error, detected source) against a mocked `URLSession`,
  mirroring how existing providers are tested.
- `TranslationServicePreset`: catalog integrity (unique ids; LLM presets carry
  baseURL+model; DeepL preset has `.deepl` kind; the DeepSeek preset carries the
  thinking-disable `extraBodyJSON`).
- `OpenAICompatibleProvider.buildRequest`: `extraBodyJSON` merges top-level keys;
  base keys win; invalid/empty JSON is ignored.

## Localization

All new user-facing strings go through `L10n` + the `.xcstrings` catalog (every
new key added to BOTH the `L10n.Key` enum and `Localizable.xcstrings`). UI copy
stays Chinese: preset menu labels, the DeepL editor's official/DeepLX hints, the
advanced extra-body field label.

## Risks / open notes

- LLM model ids and endpoints churn; defaults may age. Mitigation: every field is
  user-editable, the catalog is a single file, and the editor's Test button
  validates a real call before save.
- DeepLX reliability is best-effort by nature; the UI frames it as an advanced
  self-host option, not the default DeepL path.
- Region-specific keys (Qwen/Kimi/Zhipu intl-vs-CN) are a known support gotcha;
  the preset picks the most common endpoint and the user edits the base URL for
  their region.
