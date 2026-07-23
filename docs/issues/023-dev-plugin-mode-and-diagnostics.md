---
id: 023
title: "Script Plugins: Dev Plugin mode and diagnostics"
status: done
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 18, 20–21).

## What to build

The author loop: behind a developer-mode switch, Settings → Plugins can
register a local development directory as a Dev Plugin — loaded in place,
never copied — and a file change in that directory reloads the plugin's
context automatically, so an edit shows up in the palette in seconds.
In-place loading is structurally impossible for normally installed
plugins; only a Dev Plugin registration may point outside the app's
storage.

Diagnostics land with it: per-plugin log files capture load refusals,
watchdog kills, and capability errors; Dev Plugin mode surfaces error
details directly (a normal user sees the inline error states from 022, an
author sees the message and stack). Contexts remain inspectable so Safari
Web Inspector attaches to a running Dev Plugin.

## Acceptance criteria

- [ ] With developer mode off, no Dev Plugin affordance exists anywhere in Settings
- [ ] Registering a directory as a Dev Plugin loads it in place; editing its bundle reloads the context and updates already-visible palette rows without reinstalling
- [ ] A Dev Plugin failure shows the error detail (message and stack) to the author while installed plugins keep the plain inline error presentation
- [ ] Load refusals, watchdog kills, and capability errors append to that plugin's log file
- [ ] Removing the Dev Plugin registration removes its surfaces; the development directory is never modified by the host

## Blocked by

- 021 — sideload lifecycle and palette rows.
