---
id: 019
title: "Script Plugins prefactor: generalize the plugin registry over plugin kinds"
status: done
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 23–24).

## What to build

A pure prefactor with zero behavior change: the plugin registry's
lifecycle machinery (install state, activation ordering, transactional
uninstall, surface publication, backup reconcile, live palette
recomposition) currently assumes every plugin is a Native Plugin. Separate
what is truly Native-specific (BuiltinItem claims, provider composition,
usage-trace migration, hotkey conflict resolution) from the kind-agnostic
lifecycle core, so a second plugin kind can join the registry in a later
ticket by plugging into that core instead of duplicating it. Identity
stays typed per kind; nothing observable changes for Native Plugins.

"Make the change easy, then make the easy change" — this is the
make-it-easy step for the whole milestone.

## Acceptance criteria

- [ ] All existing registry, palette, hotkey, and backup tests pass unmodified
- [ ] The lifecycle core (install/uninstall/publication/reconcile) no longer references Native-specific concepts (claims, providers, usage traces) directly — those live in the Native-kind layer
- [ ] Installed-state persistence format is unchanged (`plugins.installed` reads and writes identically)
- [ ] No new public surface beyond what the second kind will need; no speculative hooks

## Blocked by

- None — can start immediately.
