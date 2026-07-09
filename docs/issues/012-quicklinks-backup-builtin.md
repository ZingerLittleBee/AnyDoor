---
id: 012
title: "Quicklinks: config backup/sync and 「新建快速入口」 builtin"
status: open
prd: docs/prds/2026-07-09-quicklinks.md
---

## Parent

PRD: `docs/prds/2026-07-09-quicklinks.md` (user stories 19, 23)

## What to build

**Backup/sync.** Quicklinks serialize whole — name, keyword, link,
openWithBundleID, hotkey, visibility, order — as a new section in
`BackupSnapshot` with a schema-version bump (older snapshots without the
section import cleanly). Import merges by `id`: imported wins, local-only
rows kept; keyword collisions between an imported row and a differently-`id`d
local row are resolved in favor of the imported row (local keyword cleared,
not the row deleted) so the uniqueness invariant holds post-import.
`reconcileAfterImport` reloads `QuicklinkStore` and rebuilds hotkey
snapshots so imports apply without relaunch. The favicon cache is
machine-local and never serialized. Local file-path links travel as-is;
missing paths on the target machine surface as the existing open-failure
toast.

**Builtin.** New `BuiltinItem` action case 「新建快速入口」: its provider
opens Settings at the Quicklinks tab via `SettingsOpener` (and, if the sheet
can be triggered cheaply, straight into the add sheet — otherwise landing on
the tab is enough). Must satisfy every `BuiltinCatalogInvariantTests`
contract: ActionProvider registered, unique `defaultOrder`, seeded by
`BuiltinPreferenceSeeder` at max order+1 for existing users.

## Acceptance criteria

- [ ] Export on machine A / import on machine B reproduces all Quicklinks with keywords and hotkeys live immediately (no relaunch)
- [ ] Import over existing data: same-`id` rows take the imported values; local-only rows survive; a keyword collision leaves both rows present with the imported one owning the keyword
- [ ] A pre-Quicklinks backup file imports without error and leaves local Quicklinks untouched
- [ ] 「新建」+ palette search shows 新建快速入口; committing it closes the palette and opens Settings on the Quicklinks tab
- [ ] `BuiltinCatalogInvariantTests` pass unmodified in logic (catalog data updated only)
- [ ] Unit tests pass: snapshot round-trip including the new section, merge semantics (imported-wins / local-kept / keyword-collision), old-schema decode
- [ ] `swift build` and `swift test` pass; CHANGELOG updated under Unreleased

## Blocked by

- 010 (hotkeys must exist to be serialized)
- 011 (openWithBundleID must exist to be serialized)
