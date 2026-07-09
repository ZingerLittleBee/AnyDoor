---
id: 010
title: "Quicklinks: global hotkeys, template hotkey summons argument mode"
status: open
prd: docs/prds/2026-07-09-quicklinks.md
---

## Parent

PRD: `docs/prds/2026-07-09-quicklinks.md` (user stories 14–16)

## What to build

Global hotkeys on Quicklinks, riding the existing pipeline end to end.

**Action + compilation.** New `HotkeyAction.openQuicklink(id: UUID)`.
`HotkeyCoordinator.compile` gains a quicklinks source (enabled = visible or
not — `isVisible` only hides from search; hotkeys stay live, the `KeyBinding`
precedent). `QuicklinkStore` mutations already call `refresh()` (wired in
008); verify snapshots actually update on add/edit/delete/hotkey change.

**Dispatch.** In `HotkeyCoordinator.dispatch`: plain link → open directly via
`QuicklinkOpener`; Search Template → open the command palette pre-entered
into that entry's argument mode (the state built in 009 gains a second entry
point on `CommandPaletteWindowController`). Keep `HotkeyService` free of
quicklink knowledge — everything routes through the coordinator, per the
established decoupling rule.

**Recorder.** The Settings edit sheet gains the existing hotkey recorder
(`HotkeyRecorder`), storing `keyCode`/`modifierFlags` on the model. Conflict
handling is whatever the recorder already provides — no special cases.

## Acceptance criteria

- [ ] Recording ⌃⌥⌘G on a plain Quicklink and pressing it anywhere opens the destination without the palette appearing
- [ ] Pressing the hotkey of a Search Template summons the palette already in that entry's argument mode (placeholder = its name); typing + Enter opens the substituted URL
- [ ] Editing or deleting a Quicklink updates dispatch immediately (no relaunch); a hidden (`isVisible = false`) Quicklink's hotkey still fires
- [ ] Recording inside the sheet cannot trigger existing bindings (recorder suppression path unchanged)
- [ ] Unit tests pass: `HotkeyCoordinator.compile` includes quicklink snapshots (pure `compile(…)` seam, extended signature), dispatch routing for plain vs template
- [ ] `swift build` and `swift test` pass

## Blocked by

- 009 (argument mode must exist for template hotkeys)
