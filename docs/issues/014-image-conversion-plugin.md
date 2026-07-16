---
id: 014
title: "Native Plugins: Image Conversion becomes the first plugin (tracer bullet)"
status: ready-for-agent
prd: docs/prds/2026-07-16-native-plugin-architecture.md
---

## Parent

PRD: `docs/prds/2026-07-16-native-plugin-architecture.md` (user stories 2–4, 7–8, 12, 14–18, 21, 26–29, 32)

## What to build

The end-to-end tracer bullet: **PluginRegistry** (the single new seam —
compile-time plugin list, install-state store, exclusive claim lookups,
transactional install/uninstall lifecycle) plus **Image Conversion extracted
into its own plugin module**, installable and uninstallable from a new
minimal **Plugins tab** in Settings.

Uninstalled means invisible everywhere the feature previously appeared: no
panel row, no palette entry, no recordable or firing hotkey (snapshot
compilation gains the installed set as an input), no window, no permission
requests. Deactivate cancels an in-flight Conversion Run before surfaces go
away. All user data (Conversion Records, per-command preferences, recorded
hotkeys) is retained; reinstalling restores the exact previous setup without
a relaunch in either direction. The builtin-catalog invariant grows the claim
rule: every command is claimed by exactly one owner — a plugin or the Core.

The Plugins tab lists available plugins with localized name, description,
and install state; for this slice Image Conversion is the only entry.
Uninstall shows the confirmation described in the PRD (for this plugin the
only side effect is cancelling in-flight work). UI copy 「插件」/「安装」/
「卸载」 per the glossary; all strings localized (Chinese + English). Add a
CHANGELOG entry under Unreleased and update the project-structure docs.

## Acceptance criteria

- [ ] The Plugins tab installs and uninstalls Image Conversion with immediate effect, no relaunch
- [ ] While uninstalled: no panel row, no palette result, no hotkey fires, and the window cannot be summoned by any path
- [ ] Uninstalling during an active Conversion Run cancels the run; nothing continues in the background
- [ ] Reinstalling restores Conversion Records, visibility/order preferences, and previously recorded hotkeys
- [ ] Registry lifecycle is tested with the real plugin instance (install surfaces appear, uninstall reverts, a throwing deactivate leaves the plugin installed)
- [ ] The catalog invariant suite verifies exclusive claims; hotkey-compile tests verify uninstalled bindings never compile
- [ ] With the plugin installed, image conversion behaves exactly as before the extraction (existing tests pass unmodified where behavior is unchanged)

## Blocked by

- 013 — plugin interface module.
