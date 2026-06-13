# Command Palette Developer Tools — Design & Implementation Plan

Date: 2026-06-14
Branch: `feature/command-palette-dev-tools` (off `feature/p0-quick-wins`)

A set of inline developer conversions surfaced directly in the command palette,
isomorphic to the existing `Calculator`: pure functions over the query string that
produce copy-on-Return result rows. No new model, no new window, no new permission.

## Market context

From the macOS-utility research (P0-后续 candidate, priority=medium, effort=medium):
"开发者一次性小工具(JSON/Base64/时间戳/UUID/哈希/URL 编解码)…正好处在命令面板
二级菜单 + 内联结果的形式零侵入接入。" The critique stressed keeping the pure-function
discipline that Calculator established.

## Design principle: mirror Calculator exactly

`Calculator.evaluate(query:) -> CalcResult?` is a pure, total facade called from
`CommandPaletteState.calcSection(matching:)`, which inserts a one-row section at the
top of `filteredSections`; committing a `.calcResult` row copies `copyText` and toasts.

Dev tools reuse this shape, with one structural difference: **one query can yield
multiple result rows** (e.g. a timestamp expands to local / UTC / ISO8601). So the
facade returns an *array*, and each row carries its own stable id.

## Core types

New `Sources/AnyDoor/Services/DevTools/`:

```
struct DevToolResult: Hashable, Sendable {
    let toolID: String      // stable, fine-grained: "base64.encode", "ts.utc", "hash.sha256"
    let output: String      // row title AND clipboard text — the conversion result
}

enum DevTools {             // pure, total — never throws, never crashes
    static func detect(query: String, now: Date? = nil, timeZone: TimeZone = .current) -> [DevToolResult]
}
```

**As-built note:** `DevToolResult` carries only `toolID` + `output` — no `L10n.Key` —
so the pure core has zero UI/localization dependency. The view layer maps `toolID` to
a localized tool-name label via `CommandPaletteRow.devToolLabelKey(_:)` and stores the
resolved string in the row's `subtitle`.

`detect` runs every converter and concatenates their non-nil rows in a fixed order.
Empty array ⇒ no section. Each converter is a private pure function; converters live
in one file per family (`Base64Tool`, `URLCodecTool`, `JSONTool`, `HashTool`,
`TimestampTool`) or as private static funcs in `DevTools.swift` — whichever keeps each
under ~60 lines.

`now`/`timeZone` are injected so timestamp rendering is deterministic in tests
(default `.current` in production).

## First-version tool set

All deterministic pure conversions. Two trigger styles:

| Tool | Trigger | Rows produced |
|------|---------|---------------|
| Base64 | explicit `base64 <text>` | `base64.encode`; plus `base64.decode` if the body itself decodes to valid UTF-8 |
| URL encode/decode | explicit `url <text>` | `url.encode` (percent-encode); plus `url.decode` if `removingPercentEncoding` changes the body |
| JSON format | **auto**: body trimmed starts with `{` or `[` and `JSONSerialization` parses it | `json.pretty` (sorted keys, 2-space) + `json.minify` |
| Hash | explicit `md5 <text>` / `sha1 <text>` / `sha256 <text>` | one row, lowercase hex (CryptoKit `Insecure.MD5` / `Insecure.SHA1` / `SHA256`) |
| Unix timestamp → date | **auto**: body is exactly 10 (seconds) or 13 (milliseconds) digits, all numeric | `ts.local` + `ts.utc` + `ts.iso` (ISO8601) |

### Trigger discipline (don't steal command/app/port search)

- **Explicit-keyword tools** (`base64` / `url` / `md5` / `sha1` / `sha256`) require the
  leading keyword + a space + non-empty body. Zero ambiguity, never auto-fires.
- **Auto-detected tools** fire only on strong, unambiguous signals:
  - JSON: trimmed body begins with `{`/`[` *and* parses. Plain words never match.
  - Timestamp: body is *exactly* 10 or 13 ASCII digits. (Port search needles are 1–5
    digits, so no overlap; a 10-digit Unix second covers 2001–2286.)
- Mirrors Calculator's `looksLikeExpression` gate philosophy: a bare word or short
  number falls through to normal search.

### Explicitly out of first version (documented)

- **UUID generation** and **`now` → timestamp**: both have a random / clock side
  effect, which breaks the pure-function instant-preview contract — `filteredSections`
  is a recomputed `var`, so a per-recompute-changing value would flicker the row and
  destabilize its id. If wanted later, model them as *commit-time* actions, not preview
  rows.
- **Date string → timestamp** (reverse direction): natural-language/date parsing is
  ambiguous; first version ships the deterministic number→date direction only.

## Wiring (mirrors `.calcResult` everywhere)

New `PanelEntry.Source.devTool(DevToolResult)` — command-palette-only. Update every
exhaustive switch:

1. `PanelEntry.Source` — add the case.
2. `PanelEntry.id(for:)` → `"devTool:\(result.toolID):\(result.output)"` (stable + unique).
3. `PanelEntry.localizedTitle()` → `result.output`.
4. `CommandPalettePicker.iconPath` (nil branch) — add `.devTool`.
5. `CommandPalettePicker.showsSubtitle` (true branch) — add `.devTool` (subtitle = tool label).
6. `CommandPaletteWindowController` prewarm switch (nil branch) — add `.devTool`.
7. `CommandPaletteWindowController.commit` `.devTool(result)` — copy `result.output`,
   `noteSelfWrite`, toast `.success(L(.toastCalcCopied, result.output))` (reuse existing key).
8. `PanelSettingsView` `apply(hotkey:)` / `clearHotkey(for:)` — add `.devTool` to the
   command-palette-only (non-bindable) branch.

`CommandPaletteRow` subtitle rendering: it currently shows `entry.subtitle` verbatim.
The dev-tool entry stores the **localized** tool label in `subtitle` at build time
(`L(result.titleKey)`), consistent with how `hostEntry` pre-resolves `L(.commandPaletteHostsActive)`.

### Section assembly

`CommandPaletteState.devToolsSection(matching:)` builds a section titled
`.commandPaletteSectionDevTools` from `DevTools.detect(query:)`, one `PanelEntry` per
`DevToolResult` (symbol `"hammer"` / `"curlybraces"` per family — single `"hammer"` is
fine for v1). Insert into `filteredSections` just below the calculator row
(calc handles arithmetic, dev tools handle text/format — triggers don't overlap):

```
if let calc = calcSection(...) { sections.insert(calc, at: 0) }
if let dev = devToolsSection(...) { sections.insert(dev, at: calc == nil ? 0 : 1) }
```

(Insert dev tools after ports/hosts/calc so a numeric port query still prioritizes ports;
final index policy validated by tests.)

## L10n keys (new)

- `commandPalette.section.devTools` — en "Developer Tools", zh "开发者工具"
- `devTool.base64.encode` / `.base64.decode` — en "Base64 Encode/Decode", zh "Base64 编码/解码"
- `devTool.url.encode` / `.url.decode` — zh "URL 编码/解码"
- `devTool.json.pretty` / `.json.minify` — zh "JSON 美化/压缩"
- `devTool.hash.md5` / `.sha1` / `.sha256` — en "MD5/SHA-1/SHA-256", zh same
- `devTool.timestamp.local` / `.utc` / `.iso` — zh "本地时间/UTC/ISO 8601"

Add all to `Localizable.xcstrings`; the build-tool plugin fails the build on a missing
translation, and `LocalizationCoverageTests` enforces key↔catalog parity.

## Tests (TDD, pure-function first)

`DevToolsTests` (new), one behavior per test:
- `base64 hello` → encode row `aGVsbG8=`; round-trips a decode row.
- `url a b&c` → `a%20b%26c`; decode row for an encoded input.
- JSON auto: `{"b":1,"a":2}` → pretty row has sorted keys + newlines; minify row is compact.
- Hashes: known vectors — `md5 abc` = `900150983cd24fb0d6963f7d28e17f72`, `sha256 abc`
  = `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`, `sha1 abc`
  = `a9993e364706816aba3e25717850c26c9cd0d89d`.
- Timestamp: `detect("1700000000", now: nil, timeZone: TimeZone(identifier: "UTC")!)`
  → utc row `2023-11-14 22:13:20` (or chosen format), iso row `2023-11-14T22:13:20Z`;
  13-digit `1700000000000` matches as milliseconds.
- Negative gates: `hello`, `42`, `8080`, `git status` → empty array (no row).

`CommandPaletteTests`: a `CommandPaletteState` with query `md5 abc` surfaces a
"Developer Tools" section whose row title is the digest. `PanelEntry.id(for:.devTool)`
/ `localizedTitle()` unit checks.

`CommandPaletteOptions`/settings: no change (dev tools are root-search rows, not an
option parent — no second-level menu in v1).

## Build / verification

- `swift build` (Swift 6 strict concurrency) — `DevToolResult` is `Sendable`; converters
  are pure static funcs, no shared state.
- `swift test` — new `DevToolsTests`, extended `CommandPaletteTests`, existing
  localization-coverage tests (now requiring the new catalog keys).
- CryptoKit is a system framework (macOS 10.15+); no new SPM dependency.

## Commit plan (English Conventional Commits, no push)

1. `feat(palette): add Base64/URL/JSON/hash/timestamp dev tools core`  (pure `DevTools` + tests)
2. `feat(palette): surface developer tools section in command palette` (wiring + L10n + commit path)

(Or one combined `feat(palette): add inline developer tools` if the diff stays small.)

---

# Follow-up: Raycast-style scope badge

Date: 2026-06-14

When a user types a scoped dev-tool keyword, the keyword is absorbed into a search-bar
badge (pill) that replaces the magnifying glass, and the list becomes exclusive to that
tool's rows — matching Raycast's command-scope interaction.

## Decisions (confirmed with the user)

- **Triggers:** space *and* Tab. Typing `base64 ` (keyword + space), pasting
  `base64 <body>`, or pressing Tab on a bare keyword all absorb the scope.
- **Exclusive:** while scoped, only that tool's rows show — no app / command / port
  search leaks in.
- **Badge label:** canonical tool name — `Base64` / `URL` / `MD5` / `SHA-1` / `SHA-256`.
- **Scope set:** only the explicit-keyword tools (`base64 url md5 sha1 sha256`). JSON and
  timestamp are auto-detected (no keyword) and never badge.

## Core

`DevToolScope` (enum: base64/url/md5/sha1/sha256) with `keyword`, `badgeLabel`, and
`init?(keyword:)`. `DevTools.results(scope:body:)` evaluates a single tool against a bare
body, reusing the same body-level converters `detect()` already calls (refactored out so
both paths share one implementation).

## State (`CommandPaletteState`)

- `private(set) var activeDevToolScope: DevToolScope?`
- `absorbDevToolScopeIfNeeded()` — space trigger, called from the query `.onChange`;
  splits on the first whitespace, absorbs when the leading token is a scoped keyword,
  keeps the remainder as the body. Re-entrant-safe (no-ops once a scope is active).
- `tryAbsorbDevToolScope() -> Bool` — Tab trigger; absorbs when the whole query is a
  bare keyword.
- `removeDevToolScope()` — sheds the badge.
- `filteredSections` early-returns an exclusive single-tool section when scoped.
- `handleEscape()` escalates: clear body → shed badge → dismiss.
- `popToRoot()` / `enterOptions()` clear the scope (it is root-only).

## Wiring

- `searchField` renders `scopeBadge(_:)` in place of the glass when scoped, with a
  "type to convert" placeholder (`commandPalette.devTool.scopePlaceholder`).
- The window controller key monitor handles Tab (48 → `tryAbsorbDevToolScope`, swallowed
  at root so focus doesn't jump) and Backspace (51 → `removeDevToolScope` when the body
  is empty, before the existing options-level pop).

## Tests

`DevToolsTests`: scope keyword parsing, badge labels, `results(scope:body:)` for each
family. `CommandPaletteTests`: space/Tab absorb, paste-with-body, non-keyword no-absorb,
exclusive section, remove, and the two Esc-escalation outcomes.

## Known trade-off

`url` / `md5` etc. are real words; typing one followed by a space enters its scope. This
is intentional (matches Raycast) and fully recoverable — Backspace on the empty body, or
Esc, sheds the badge.
