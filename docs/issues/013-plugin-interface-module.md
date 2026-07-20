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

## Final implementation note (2026-07-20)

The protocol was narrowed after the pilot plugins exercised the boundary. Its
final contribution surface is providers, palette option parents, namespaced
palette row sources, and an optional panel popover. Plugin-owned windows stay
inside their modules and are reached through those registered surfaces;
settings-section and generic window contributions were removed because no Core
caller needed them. `NativePluginCatalog`, not `PluginRegistry`, owns the
compile-time schema and factory inventory.

## Acceptance criteria

- [x] A new library target exists containing the command catalog, plugin protocols, row descriptors, and host-scoped row-source key; the app target depends on it
- [x] The plugin protocol expresses the contribution surfaces proven by the pilots, lifecycle, schema, and usage-trace predicate, without speculative window or settings requirements
- [x] `swift build` and the full existing test suite pass; the prefactor itself changed no user-visible behavior
- [x] `PanelEntry` and `Source` did not move — the interface target has no dependency on palette/UI types
- [x] No file left behind re-exports or aliases moved types "for compatibility" — call sites import the new module directly

## Blocked by

None — can start immediately.
