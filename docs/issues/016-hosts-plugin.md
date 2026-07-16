---
id: 016
title: "Native Plugins: Hosts becomes a plugin with transactional uninstall"
status: ready-for-agent
prd: docs/prds/2026-07-16-native-plugin-architecture.md
---

## Parent

PRD: `docs/prds/2026-07-16-native-plugin-architecture.md` (user stories 5–6, 9, 14–20, 22)

## What to build

Hosts extracted into its own plugin module — the heavy-side-effect pilot.
The plugin claims its command, contributes the panel popover, the editor
window, the palette option parent, and the profile row source through the
extension points from 014/015, and appears in the Plugins tab beside Image
Conversion. Installed, everything behaves exactly as today: editor window,
helper approval flow, profile toggling from panel and palette, privileged
and AppleScript-fallback writes.

Uninstall is the transactional path the glossary defines. The confirmation
dialog states what will be reverted (active profiles deactivated). Then
deactivate runs first: active profiles are deactivated through the normal
writer path; the privileged helper is unregistered **only when no other
consumer needs it** — forced Scheduled Shutdown shares that daemon (amended
ADR-0005) — and only after side effects are fully reverted do the surfaces
unregister. A failed write or a cancelled administrator authorization leaves
the plugin fully installed with a clear error; there is no half-uninstalled
state. Host profile rows and hosts backups are retained; reinstall restores
the full setup without relaunch.

## Acceptance criteria

- [ ] Installed Hosts is behaviorally identical to pre-extraction (existing hosts tests pass unmodified where behavior is unchanged)
- [ ] Uninstalling with active profiles deactivates them; the hosts file no longer contains AnyDoor-managed active entries afterward
- [ ] Cancelling the authorization prompt (or a writer failure, exercised via the existing writer test double) aborts the uninstall: plugin still installed, surfaces intact, error surfaced
- [ ] With forced Scheduled Shutdown enabled, uninstalling Hosts leaves the helper registered and forced shutdown still works; with it disabled, the helper is unregistered
- [ ] While uninstalled: no panel popover, no palette option parent, no profile rows, no hotkey, no helper approval banner anywhere
- [ ] Reinstalling restores profiles, preferences, and hotkeys; registry lifecycle tests cover the transactional-failure path with the real plugin instance

## Blocked by

- 014 — PluginRegistry + Plugins tab.
- 015 — generic palette extension points.
