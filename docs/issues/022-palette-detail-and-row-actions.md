---
id: 022
title: "Script Plugins: markdown Detail navigation and Row Actions in the palette"
status: done
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 7–9, 14, 16).

## What to build

The full "latest posts" experience: selecting a Script Plugin row whose
descriptor declares a Detail pushes a markdown Detail view as a new
palette navigation level (system markdown parsing, no third-party
renderer), and Esc/Backspace walk back through the existing escape-policy
seam. Rows expose Row Actions — open URL, copy through the self-write
funnel, or invoke a plugin function — mapped onto the palette's existing
commit-semantics classification.

Failure presentation is part of the slice: a loading state while the
plugin builds rows or Detail, an inline error row when building fails, and
a failure toast when a Row Action fails. A plugin needing an input uses
the palette's existing Argument input mode. Everything remains invisible
the moment the plugin is uninstalled, including mid-drill-in.

## Acceptance criteria

- [ ] Committing a Detail-declaring row pushes a rendered markdown Detail; Esc/Backspace pop levels per the extended escape-policy tests
- [ ] Row Actions run with their declared commit semantics: open URL and copy close then act, plugin-function invocation reports failure as a toast
- [ ] A slow fixture shows the loading state; a failing fixture shows the inline error row; neither hangs or closes the palette
- [ ] An Argument-declaring row enters the existing Argument input mode and passes the text to the plugin
- [ ] Uninstalling while a plugin's Detail is visible discards the drill-in state and removes its rows
- [ ] Commit-intent classification stays exhaustive; new semantics are covered by the pure classifier tests

## Blocked by

- 021 — sideload lifecycle and palette rows.
