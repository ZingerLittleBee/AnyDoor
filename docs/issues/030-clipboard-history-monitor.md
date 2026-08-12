---
id: 030
github: 83
title: "Clipboard History v2: event-assisted pasteboard monitor and source policy"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decision: ADR-0016.

## What to build

Implement the module-owned serialized Clipboard Capture Monitor using only
public macOS APIs. `Command-C` and `Command-X` events are latency hints that
schedule short high-frequency observation windows. A 500 ms
`NSPasteboard.changeCount` fallback with at least 50 ms timer tolerance remains
active for menu, programmatic, accessibility, and Universal Clipboard writes.
An observed non-keyboard change briefly raises observation frequency.

The event callback only schedules observation. All pasteboard reads,
canonicalization, encoding, and persistence run outside it through ticket 028's
single snapshot pipeline. Stop the fallback while monitoring is disabled,
during sleep, and while the screen is locked. Launch, re-enable, unlock, and
migration completion establish a new baseline without importing current
content.

Implement source provenance and exclusions. Respect declared History Exclusion
Markers before reading payload bytes. Preserve declared, copy-event sampled,
observation-inferred, Unknown, and Universal Clipboard source provenance.
Excluded application and Universal Clipboard rules affect only future
observations.

Replace global watcher suppression with one module-facing self-write funnel.
Every AnyDoor and plugin pasteboard writer reports the resulting generation so
history copy/paste, translation selection reads, plugin actions, and clear
clipboard cannot recapture their own writes.

## Acceptance criteria

- [ ] Deterministic scheduler tests cover overlapping key hints, fallback ticks, post-change boosts, start/stop, sleep, lock, wake, and rapid generation changes
- [ ] The event callback performs no pasteboard read, encoding, database work, synchronous main-actor hop, or other expensive operation
- [ ] The idle fallback is 500 ms with at least 50 ms tolerance and no more than two scheduled fires per second
- [ ] Launch and every resume path establish a baseline and never retroactively capture the current pasteboard
- [ ] Consecutive human copies are observed through the event window; overwritten unobserved generations are documented rather than reconstructed
- [ ] Source precedence and Unknown/Universal Clipboard attribution match the PRD
- [ ] Excluded applications, Universal Clipboard exclusion, concealed markers, and transient markers commit no new entry
- [ ] All Core and plugin self-writes pass through one tested suppression funnel without a mutable global watcher reference
- [ ] Lightweight instrumentation exists for the final idle wakeup, CPU, Energy Impact, and consecutive-copy benchmarks

## Out of scope

Settings presentation and final performance acceptance are tickets 036 and 037.

## Blocked by

Ticket 028.
