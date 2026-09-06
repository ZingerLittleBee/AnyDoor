---
id: 037
github: 90
title: "Clipboard History v2: remove the legacy path and pass release acceptance"
status: todo
prd: docs/prds/2026-07-29-clipboard-history-v2.md
---

## Parent

PRD: `docs/prds/2026-07-29-clipboard-history-v2.md`.
Decisions: ADR-0011 through ADR-0025.

## What to build

Complete the irreversible source cutover after every behavior is available
through `ClipboardHistoryModule`. Remove `ClipboardHistoryItem` from the shared
SwiftData schema and delete the old `ClipboardHistoryStore`,
`ClipboardWatcher`, in-memory `ClipboardSearch`, persistence-aware paste path,
and obsolete compatibility helpers. Retain only the host-side read-only legacy
extraction adapter required by migration; it must not become a second live
store or dual-write path.

Update every caller and test fixture that still constructs the legacy SwiftData
model or mutates a global watcher. Verify AppDelegate's pinned shared
SwiftData path and every unrelated model remain unchanged. Confirm Config
Backup, Script Plugin pasteboard suppression, Native Plugin clipboard actions,
explicit screenshot/OCR/QR/color capture, panel providers, and application
reopen behavior through their real integration seams.

Run the PRD's release gates and record measured evidence:

- warning-free Swift build and complete Swift test suite;
- tooling verification required by CI;
- release builds for arm64 and x86_64 with FTS5/trigram probes and final
  SQLCipher symbol-binding inspection;
- release-bundle size impact;
- large-corpus search latency and memory for empty, one-character,
  two-character, and long-substring queries;
- secure-delete-heavy retention cleanup;
- fixed-duration idle wakeup, CPU, and Energy Impact against the current plain
  500 ms baseline;
- consecutive-copy loss-rate testing; and
- real-app GUI coverage of migration, paging/search, paste, retention, clear,
  restore, storage usage, source exclusions, and failure states.

Do not weaken a contract to make a benchmark pass. A failed gate returns to the
owning ticket unless the approved PRD itself must be amended.

## Acceptance criteria

- [ ] The shared SwiftData schema no longer registers `ClipboardHistoryItem`, and no production code reads or writes legacy rows after migration publication
- [ ] No legacy store, watcher singleton, in-memory full-history search, copied-file threshold, hidden count cap, or dual-write path remains
- [ ] Old shallow-helper tests are deleted once equivalent behavior is covered through the module interface
- [ ] All repository CI-equivalent build, test, tooling, warning, and universal-build commands pass
- [ ] Both architectures execute known FTS5 trigram and short-gram checks and bind GRDB's SQLite symbols to SQLCipher as specified by ADR-0013
- [ ] Search and retention benchmarks satisfy the interactive and cleanup contracts on minimum supported hardware
- [ ] Idle fallback stays within two timer fires per second and measured idle wakeups, CPU, and Energy Impact show no material regression beyond noise
- [ ] Rapid-copy testing records the event-assisted loss-rate result and the documented public-API overwrite limit
- [ ] Migration fault fixtures and a disposable real legacy store prove no unique readable copy is silently lost
- [ ] Real-app GUI acceptance covers every changed user workflow and error state on the supported macOS range available to the project
- [ ] Release-size, energy, performance, architecture, migration, and GUI evidence is attached to the implementation handoff

## Out of scope

Cloud history sync, history export/import, disk-pressure management, private
pasteboard APIs, fuzzy or semantic search, and any paid Clipboard tier remain
non-goals.

## Blocked by

Ticket 036.
