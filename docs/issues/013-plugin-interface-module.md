---
id: 013
title: "Native Plugins: extract the shared plugin-interface module (prefactor)"
status: done
prd: docs/prds/2026-07-16-native-plugin-architecture.md
---

## Parent

PRD: `docs/prds/2026-07-16-native-plugin-architecture.md` (user stories 29, 30; ADR-0005/0006/0007)

## What to build

The prefactor that makes every later slice easy: a new lean SPM library
target — the shared plugin interface — holding the closed command catalog
(`BuiltinItem` and whatever value types it drags, per ADR-0006), the Native
Plugin protocol surface (identity, localized name/description, claimed
commands, lifecycle hooks: activate / throwing deactivate /
reconcile-after-import), and the palette row descriptor type (ADR-0007,
declaration only — nothing consumes it yet).

`PanelEntry`, its `Source` enum, and their payloads stay in the app target
(ADR-0007). The move is mechanical and compiler-guided: relocate the types,
add the imports the compiler demands, change zero behavior. This is the
expand step of a wide refactor — the app must be byte-for-byte equivalent in
behavior afterward.

Glossary vocabulary (Native Plugin, Core, Claim, Install, Uninstall) is
canonical in `CONTEXT.md`; use it in all API names and doc comments.

## Acceptance criteria

- [ ] A new library target exists containing the command catalog, the plugin protocols, and the row descriptor; the app target depends on it
- [ ] The plugin protocol expresses everything the PRD's plugin-protocol decision lists (claims, contributions, lifecycle, usage-trace predicate) — even where no implementation exists yet
- [ ] `swift build` and the full existing test suite pass unchanged; no user-visible behavior differs
- [ ] `PanelEntry` and `Source` did not move — the interface target has no dependency on palette/UI types
- [ ] No file left behind re-exports or aliases moved types "for compatibility" — call sites import the new module directly

## Blocked by

None — can start immediately.
