---
id: 021
title: "Script Plugins: Sideload install/uninstall and searchable palette rows"
status: ready-for-agent
prd: docs/prds/2026-07-21-script-plugin-runtime.md
---

## Parent

Spec: `docs/issues/018-script-plugin-runtime.md` (user stories 1–6, 10,
17, 22–24).

## What to build

The first user-visible tracer bullet: Sideload a Script Plugin from
Settings → Plugins (folder picker → package copied into the app's storage),
see it listed beside Native Plugins — grouped by kind, with manifest name,
description, version, and per-language strings — and find its rows
searchable at the palette root through the existing generic plugin row
channel. Selecting a row commits its default action (full Detail
navigation arrives in a later ticket; until then commit uses the row's
declared close-then-act semantics).

Script Plugins join the registry as the second kind on the prefactored
lifecycle core: install publishes rows to an already-open palette,
uninstall removes the package copy and every surface at once while the
private key-value store is retained, and reinstalling the same id finds
its prior data. An invalid package fails installation with a clear message
and changes nothing. Script install state and data stay out of config
backup.

## Acceptance criteria

- [ ] Sideloading a sample package from Settings lists it (grouped, localized name/description/version) and its rows appear in palette root search without relaunch
- [ ] Installing an invalid package (missing fields, unknown apiVersion, duplicate id) surfaces the typed refusal and leaves Settings, registry, and disk unchanged
- [ ] Uninstall removes the package copy and all palette rows immediately, including from an already-visible palette; reinstalling the same id restores prior key-value data
- [ ] While uninstalled the plugin produces no rows and no search results anywhere
- [ ] Script Plugin install state and private storage never appear in a backup snapshot export
- [ ] Registry lifecycle tests cover the second kind alongside the real Native pilots; V1 invariants stay green

## Blocked by

- 019 — registry kind prefactor.
- 020 — runtime and capability sandbox.
