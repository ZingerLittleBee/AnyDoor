---
id: 017
title: "Native Plugins: usage-trace migration + install state in backup"
status: ready-for-agent
prd: docs/prds/2026-07-16-native-plugin-architecture.md
---

## Parent

PRD: `docs/prds/2026-07-16-native-plugin-architecture.md` (user stories 10–13, 23–25, 28)

## What to build

The two flows that make the plugin split safe for people who already run
AnyDoor.

**Migration.** A one-time, versioned backfill in the launch sequence
(following the existing seeder precedent) evaluates each plugin's
usage-trace predicate: Hosts installs when host profile rows exist **or**
the privileged helper is registered (no ghost daemon without a managing UI);
Image Conversion installs when Conversion Records exist. Everyone else —
including fresh installs — starts uninstalled. The backfill is idempotent
across relaunches and Sparkle's silent update relaunch never changes an
already-migrated installed set.

**Backup.** The installed-plugin set joins the settings-sync whitelist:
export includes it, import applies it through reconcile-after-import so
surfaces appear or disappear without a relaunch — importing "Hosts
installed" onto a machine where it never was activates it like a hands-on
install, while helper approval and other machine-local security state never
travel (existing backup policy).

## Acceptance criteria

- [ ] A store with host profile rows migrates to Hosts installed; one with only a registered helper (no profiles) also installs Hosts
- [ ] A store with Conversion Records migrates to Image Conversion installed; a fresh store migrates to both uninstalled
- [ ] Running the migration twice changes nothing (idempotence, seeder-style in-memory container tests)
- [ ] Backup export contains the installed set; import installs/uninstalls accordingly and surfaces update without relaunch
- [ ] Helper approval state does not appear in an exported backup, and an import never registers a helper by itself
- [ ] A user upgrading with an installed set already present (post-migration) keeps it unchanged across app updates

## Blocked by

- 016 — Hosts plugin (both pilots' traces and reconcile paths must exist).
