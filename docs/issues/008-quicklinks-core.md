---
id: 008
title: "Quicklinks: model, opener, Settings CRUD, palette row (tracer bullet)"
status: done
prd: docs/prds/2026-07-09-quicklinks.md
---

## Parent

PRD: `docs/prds/2026-07-09-quicklinks.md` (user stories 1–4, 16, 21, 22, 24, 25)

## What to build

The end-to-end tracer bullet: create a Quicklink in Settings, find it in the
command palette, press Enter, and the destination opens.

**Model + store.** `Quicklink` becomes the seventh SwiftData `@Model` — all
fields scalar or optional-scalar (`id`, `name`, `keyword: String?`, `link`,
`openWithBundleID: String?`, `keyCode: Int?`, `modifierFlags: Int?`,
`isVisible: Bool = true`, `displayOrder: Double = 0`, `createdAt`). Register
it in the ModelContainer schema and update CLAUDE.md's "exactly six @Model
types" wording. A `@MainActor` observable `QuicklinkStore` owns CRUD following
the `PanelStore` discipline (mutations save SwiftData, rebuild published
state, call `HotkeyCoordinator.shared.refresh()` — the refresh is a no-op
until issue 010 but wire the call now).

**Classifier + opener.** `QuicklinkDestination.classify(link:)` is a pure
function inferring web / deeplink / file / folder / search-template from the
string (`~` expansion for paths; `{query}` presence marks a template — later
issues consume that case, this one only needs to *classify* it).
`QuicklinkOpener` turns `(link, argument?, openWith?)` into an open *plan*
and executes it solely via `NSWorkspace`. Unopenable target (missing file) →
failure toast. Keyword/openWith/hotkey have no UI yet; fields exist, dormant.

**Settings tab.** New sidebar entry 「快速入口」 in `SettingsView`: a list
(icon placeholder, name, link) with add/edit sheet carrying name, link, and
the visibility toggle, plus swipe/context delete and drag reorder
(`displayOrder`). Validation: link non-empty; nothing else. Overlay-scroller
rules apply.

**Palette row.** `PanelEntry.Source.quicklink(id: UUID)`; visible Quicklinks
join the root results mixed with apps/builtins, fuzzy-matched on name (keyword
matching arrives in 009). `CommandPaletteCommitIntent.classify` declares the
new case: plain link → close-then-act; search-template → stay-open (until 009
lands, a template row may simply act like close-then-act on its raw link is
NOT acceptable — instead hide template entries from results in this slice so
no half-behavior ships). Enter opens via `QuicklinkOpener`.

All UI copy localized (zh-Hans + en) through the string catalog; feature name
「快速入口」. CHANGELOG entry under Unreleased. Update the project-structure
docs for the new Services/Quicklinks area.

## Acceptance criteria

- [ ] Creating 「AnyDoor 仓库」 → `~/Bee/AnyDoor` in Settings, then typing "any" in the palette shows the row; Enter closes the palette and Finder opens the folder
- [ ] A `https://github.com` Quicklink opens in the default browser; a `slack://open` link routes to Slack; a link to a deleted file shows a failure toast
- [ ] A Quicklink with `{query}` in its link is classified as a template and does not appear in palette results in this slice
- [ ] Toggling 隐藏 removes the entry from palette results without deleting it; reorder persists across relaunch
- [ ] Existing palette behaviors (apps, ports, calculator, builtins) are unchanged
- [ ] Unit tests pass: classifier edge matrix (scheme-less host:port, `~` paths, spaces, `{query}` in fragment), opener plan (missing file → failure), store CRUD + link-non-empty validation against an in-memory container
- [ ] `swift build` and `swift test` pass; strings resolve in zh-Hans and en; launch migration from an existing store works (new model added, no data loss)

## Blocked by

None - can start immediately
