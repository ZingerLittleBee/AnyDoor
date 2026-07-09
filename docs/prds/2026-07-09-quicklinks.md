# PRD: Quicklinks

- **Status:** ready-for-agent
- **Date:** 2026-07-09
- **Tracker:** local (`docs/prds/`, issues under `docs/issues/`)
- **Glossary:** see `CONTEXT.md` (Quicklink, Link, Search Template, Keyword, Open With)
- **ADR:** `docs/adr/0001-untyped-quicklink-template.md`

## Problem Statement

Users open the same handful of destinations dozens of times a day: a project
folder in VS Code, a GitHub search, a Notion workspace, a Slack deeplink, a
meeting link. Today each of those lives somewhere different — browser
bookmarks, Finder sidebar, muscle memory — and none is reachable from the
keyboard-first command palette that already launches apps and toggles
builtins. App Shortcuts only launch apps; the palette has no way to open "an
arbitrary entry point".

## Solution

**Quicklinks** (快速入口): user-defined, searchable, hotkey-capable entries
that open any destination — a web URL, an app deeplink, a local file or
folder, or a **Search Template** containing `{query}`. Quicklinks are managed
in a new Settings tab, surface in the command palette's root results mixed
with apps and builtins, and can optionally carry a global hotkey and a short
**Keyword** (e.g. `gh`) so `gh AnyDoor` opens a GitHub search in one stroke.
Each Quicklink may pin an **Open With** app (VS Code for a folder, a specific
browser for a URL); otherwise the system default handler is used. Quicklinks
are pure configuration and ride along in config backup/sync.

Explicitly *not* in scope for v1: the menu-bar panel (palette + hotkey only),
team sharing, tags, manual icon selection.

## User Stories

1. As a user, I want to create a Quicklink with a name and a link in Settings, so that my daily destinations become searchable entries.
2. As a user, I want to paste any string as the link — `https://…`, `slack://…`, `~/Bee/AnyDoor`, a file path — without declaring what kind it is, so that creating an entry is zero-thought.
3. As a palette user, I want Quicklinks to appear in the root search results mixed with apps and builtins, matched on name and keyword, so that they feel like first-class openable things.
4. As a palette user, I want Enter on a plain Quicklink to close the palette and open the destination, so that the interaction matches launching an app.
5. As a user, I want a link like `https://github.com/search?q={query}` to be recognized as a Search Template, so that one entry covers infinitely many searches.
6. As a palette user, I want Enter on a Search Template to drill into an argument-input mode (search field becomes the argument field, placeholder shows the Quicklink's name), so that supplying the argument stays inside the palette.
7. As a palette user in argument mode, I want Enter with a non-empty argument to substitute, open, and close — and Enter on an empty argument to do nothing — so that I can never open a meaningless empty search.
8. As a palette user in argument mode, I want Esc to follow the palette's existing escape semantics (clear text first, then pop back to root), so that navigation feels uniform.
9. As a user, I want to assign an optional short Keyword (e.g. `gh`) distinct from the display name, so that my trigger vocabulary stays terse.
10. As a palette user, I want typing `gh AnyDoor` at the root to show a pinned row "GitHub 搜索 — AnyDoor" that opens the substituted URL on Enter, so that keyword + argument is a single stroke.
11. As a palette user, I want inline arguments to trigger only on an exact (case-insensitive) first-token match against a keyword or full name, so that fuzzy matches never mis-split my query into a bogus argument.
12. As a user, I want to pin an Open With app per Quicklink (VS Code for a folder), so that the same target can have differently-purposed entries.
13. As a user whose pinned app was uninstalled, I want the open to fall back to the system default with a toast, so that a stale reference never hard-fails.
14. As a user, I want to record a global hotkey on a Quicklink, so that my highest-frequency entries skip the palette entirely.
15. As a user, I want a hotkey on a Search Template to summon the palette pre-entered into that entry's argument mode, so that templates and hotkeys compose instead of conflicting.
16. As a user, I want to hide a Quicklink from palette search while keeping its hotkey live, so that hotkey-only entries don't pollute results.
17. As a user, I want icons derived automatically — pinned app's icon, file/folder system icon, deeplink handler's icon, fetched favicon for web URLs — so that a list of entries is scannable without me curating artwork.
18. As a user, I want favicon fetches cached on disk with a graceful symbol fallback, so that icons cost one request ever, and offline never breaks the list.
19. As a user, I want a "新建快速入口" entry in the palette that opens the Settings tab, so that the "thought → entry" loop closes without leaving the keyboard.
20. As a user, I want keyword uniqueness enforced (case-insensitive) at save time, so that inline-argument matching stays deterministic.
21. As a user, I want any non-empty string to be saveable as a link, so that exotic deeplink schemes are never rejected by an over-eager validator.
22. As a user opening a link whose file no longer exists, I want a clear failure toast, so that stale entries fail loudly but gently.
23. As a user who syncs settings between machines, I want Quicklinks (including keywords and hotkeys) in config backup, so that my entry vocabulary follows me.
24. As a Chinese or English user, I want the whole feature localized like the rest of the app, so that it feels native.
25. As a user, I want the palette's existing behaviors (ports, calculator, dev tools, app search) completely unchanged, so that Quicklinks is additive.

## Implementation Decisions

- **Untyped template string** (see ADR 0001). `link` is one `String`; a pure
  classifier (`QuicklinkDestination.classify(link:)`) infers web / deeplink /
  file / folder / search-template at open time. `~` is expanded for paths.
  Classifier edges (scheme-less `localhost:3000`, `{query}` in a fragment,
  paths with spaces) are unit-tested.
- **Palette + hotkey only.** Quicklinks do not enter the menu-bar panel or
  `PanelStore.rebuild()`'s three-source merge. The seventh data surface is the
  palette root, fed by a dedicated store.
- **Seventh SwiftData model.** `Quicklink`: `id` (unique UUID), `name`,
  `keyword: String?`, `link`, `openWithBundleID: String?`, `keyCode: Int?`,
  `modifierFlags: Int?`, `isVisible: Bool = true`, `displayOrder: Double = 0`,
  `createdAt`. All scalar/optional-scalar — no transformable columns (hard
  migration rule). Register in the ModelContainer schema and update project
  docs that state the model count.
- **`isVisible` follows the `KeyBinding` precedent**: hidden entries vanish
  from palette search but their hotkeys still dispatch.
- **Store pattern.** A `@MainActor` observable `QuicklinkStore` owns CRUD,
  mirrors `PanelStore`'s discipline: every mutation saves SwiftData, rebuilds
  published state, and calls `HotkeyCoordinator.shared.refresh()`.
- **One opener, one exit.** A `QuicklinkOpener` service performs argument
  substitution (percent-encode the argument, replace **all** `{query}`
  occurrences), resolves Open With, and funnels every open through
  `NSWorkspace` (`open(_:)` / `open(_:withApplicationAt:…)`). Missing pinned
  app → fall back to system default + toast; unopenable path → failure toast.
- **Root search: mixed, not sectioned.** Quicklinks join the root fuzzy match
  as ordinary entries, matched on name *and* keyword. New
  `PanelEntry.Source.quicklink(id: UUID)`; `CommandPaletteCommitIntent.classify`
  declares templates stay-open (drill to argument mode) and plain links
  close-then-act — the compiler forces this when the case is added.
- **Inline arguments are exact-match only.** A pure resolver
  (`(query, entries) → (quicklink, argument)?`) fires when the first
  whitespace-delimited token equals (case-insensitively) a Search Template's
  keyword or full name; the remainder is the argument. On hit, a synthesized
  argument-carrying row is pinned atop results (Ports-section precedent) with
  the substituted URL as subtitle. No fuzzy-match argument splitting, ever.
- **Argument mode is a new palette stack state** alongside `.root` ⇄
  `.options`: entering clears the query, sets the placeholder to the
  Quicklink's name; Enter with empty text is a no-op; Esc follows the existing
  `handleEscape` policy (clear first, then pop). All transitions live in
  `CommandPaletteState` as testable policy.
- **Hotkeys ride the existing pipeline.** `HotkeyAction.openQuicklink(id:)`;
  `HotkeyCoordinator.compile` gains a quicklinks source; store mutations
  trigger `refresh()`. Dispatch: plain link → open directly; Search Template →
  open the palette pre-entered into that entry's argument mode. Conflict
  detection is whatever the existing recorder already does — no special cases.
- **Icons are derived, never chosen.** Pinned app → `AppIconCache`;
  file/folder → `NSWorkspace.shared.icon(forFile:)`; deeplink →
  `urlForApplication(toOpen:)`'s handler icon; web → async favicon fetch
  (`https://<host>/favicon.ico`, disk-cached, fetched lazily and re-fetched
  never) with SF Symbol `link` fallback. The favicon cache is machine-local.
- **Settings: new sidebar tab 「快速入口」** — list with add/edit sheet (name,
  link, keyword, Open With picker via `InstalledAppsScanner`, hotkey recorder,
  visibility toggle) plus drag reorder. Save-time validation: keyword unique
  case-insensitively among Quicklinks; link non-empty — nothing else.
- **New builtin 「新建快速入口」** (action kind): palette-reachable, opens
  Settings at the Quicklinks tab via `SettingsOpener`. Must satisfy
  `BuiltinCatalogInvariantTests` (provider protocol, unique `defaultOrder`).
- **Backup/sync: full rows.** Quicklinks serialize entirely (keyword, hotkey
  included) into `BackupSnapshot` with a schema version bump; import merges by
  `id` (imported wins, local-only kept); `reconcileAfterImport` refreshes the
  store and hotkey snapshots. Local paths travel as-is — a path missing on the
  other machine surfaces as an open-failure toast, accepted.
- **Localization** through the string catalog; the feature name in UI copy is
  「快速入口」, code vocabulary is *Quicklink* per the glossary.

## Testing Decisions

Behavior at seams, per repo convention; window controllers stay manually
verified.

- **Primary seam — destination classification + substitution + open planning.**
  The classifier and the opener's *plan* (which URL, which app, or which
  failure) are pure given `(link, argument, openWith, installed-apps lookup)`;
  assert the plan, not `NSWorkspace` side effects. Covers `~` expansion,
  percent-encoding, replace-all `{query}`, empty-argument rejection,
  missing-app fallback.
- **Inline-argument resolver** — exact-token hit/miss matrix: keyword hit,
  full-name hit, case-insensitivity, fuzzy near-miss must *not* fire,
  multi-word arguments, keyword with no template.
- **Palette state policy** — argument-mode transitions in
  `CommandPaletteState`: enter/commit/empty-Enter/Esc-clear/Esc-pop, plus
  `CommandPaletteCommitIntent.classify` for both quicklink variants.
- **Store + backup** — CRUD against an in-memory container; keyword-uniqueness
  rejection; snapshot round-trip and merge semantics (imported wins,
  local-only kept). Prior art: translation/clipboard store tests,
  `BackupCodec` tests.
- **Catalog invariants** — the new builtin passes
  `BuiltinCatalogInvariantTests` unmodified.

## Out of Scope

- Menu-bar panel rows or submenu for Quicklinks.
- Team sharing, tags, import from Raycast/browsers.
- Manual icon selection or custom icon upload.
- Link format validation beyond non-empty; multiple distinct placeholders or
  named/defaulted placeholders (`{query default=…}`) — single `{query}`
  vocabulary only.
- Runtime "open with…" choosers (⌘Enter menus); Open With is fixed per entry.
- Frecency/usage-based ranking of results.

## Phases

| Issue | Slice |
|---|---|
| `docs/issues/008` | Core: model, store, classifier, opener, Settings CRUD, palette row (tracer bullet) |
| `docs/issues/009` | Search Templates: argument mode, keyword + inline arguments |
| `docs/issues/010` | Hotkeys: recorder, dispatch, template → argument mode |
| `docs/issues/011` | Open With + icons |
| `docs/issues/012` | Backup/sync + 「新建快速入口」 builtin |
