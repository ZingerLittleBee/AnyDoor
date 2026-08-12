---
id: 036
github: 89
title: "Clipboard History v2: settings, migration UI, and production lifecycle"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0011 through ADR-0025.

## What to build

Wire one concrete `ClipboardHistoryModule` into the production host.
`AppDelegate` constructs it, runs ticket 034's migration before passive
observation, injects it into providers and window controllers, and starts
monitoring only after the store is ready. Store Unavailable and migration
failure remain explicit non-destructive states with retry; reset is separately
confirmed.

Complete Clipboard Settings:

- passive monitoring remains enabled by default and device-local;
- Retention Period exposes every approved preset with 30 days as default;
- Automatic Image Text Indexing is off by default and includes the no-backfill
  tip directly below its switch;
- excluded applications and the disabled-by-default Universal Clipboard rule
  affect only future capture;
- exact History Storage Usage is visible without disk-pressure warnings or
  emergency cleanup controls; and
- copy-only behavior remains device-local.

Fresh installations seed editable exclusions for Apple Passwords and Keychain
Access. Upgrades merge those defaults once without restoring one the user
previously removed. “Ignore Source” preserves the selected history entry and
is unavailable when its source is Unknown.

Implement confirmation flows for retention reduction and Clear History. Clear
History always confirms and includes “also clear tagged and favorite entries”
as an unchecked checkbox with a live affected count. Implement Store
Unavailable reset confirmation, migration progress/failure/retry, unavailable
file errors, and Restore File… / Restore Files… destination panels with
explicit collision handling.

Keep tag definitions, order, and excluded-source rules in the portable settings
surface while history membership, monitoring, retention, copy-only behavior,
and OCR eligibility remain device-local. Config Backup and Config Sync must
never include history rows, payloads, keys, migration state, or local
membership, and restore must never enable monitoring.

Route every Core and plugin pasteboard write through ticket 030's self-write
funnel. Explicit screenshot, OCR, QR, and color tools call the module's explicit
capture operation even when passive monitoring is disabled.

## Acceptance criteria

- [ ] Production startup has one injected module instance and never starts monitoring before migration/store readiness
- [ ] Settings defaults, presets, tooltips, source rules, and portability boundaries match the PRD exactly
- [ ] Apple Passwords and Keychain Access are editable fresh-install defaults, and the one-time upgrade merge never resurrects an explicit removal
- [ ] Retention and Clear History confirmations display revision-safe affected counts and never delete an unconfirmed or changed set
- [ ] Clear History's protected-entry checkbox defaults unchecked and preserves tag definitions, settings, and the system pasteboard
- [ ] Clear History advances the monitor baseline so the unchanged live pasteboard is not captured again
- [ ] Migration, Store Unavailable, corrupt-payload, unavailable-file, and operation-failure states expose only the approved retry/reset/restore behavior
- [ ] Restore destination handling keeps encrypted owned payloads on every partial failure and handles pre-existing output collisions explicitly
- [ ] History Storage Usage refreshes after mutations and when Settings appears, with no proactive disk-pressure warning
- [ ] Config Sync/Backup fixtures prove portable definitions survive while history content, keys, and device-local behavior do not move
- [ ] Explicit AnyDoor tools record their outputs when monitoring is disabled, while ordinary self-writes remain suppressed
- [ ] New and changed user-facing strings are present in both English and Simplified Chinese catalogs

## Out of scope

Removal of the old implementation and release-level performance, energy,
universal-build, and GUI acceptance remain ticket 037.

## Blocked by

Tickets 030, 034, and 035.
