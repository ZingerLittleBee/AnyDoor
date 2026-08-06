# testloop — 2026-08-06 — clipboard-history-v2

**Verdict:** repeatable gates passed; physical-input and hardware confirmation
remain · **Rounds:** 6 completed, 1 blocked before the first GUI action

## Covered

- Passed the first-party warning gate, 1,727 XCTest cases (5 skipped, 0
  failed), 33 Swift Testing cases, 225 clipboard-filtered cases (5 skipped, 0
  failed), mise-managed `pnpm verify`, and the arm64/x86_64 release build.
- Re-ran 278 focused clipboard tests across migration, encrypted storage,
  capture scheduling, OCR/QR indexing, retention, duplicate reuse, search,
  lifecycle recovery, pasteboard materialization, settings, selection, Quick
  Look geometry, and plugin bridges. There were no failures; one child-process
  probe was skipped by design and its parent cross-identity test passed.
- Migrated a disposable legacy profile containing 161 entries, including one
  owned file payload. Publication retained all 161 entries and the migration
  completed in 0.791 seconds without touching the production profile.
- Ran the opt-in release benchmark with 100,000 entries. Search p95 stayed below
  100 ms for empty, one-character, two-character, and long-substring queries;
  RSS grew by 3,440,640 bytes. Retention cleanup removed the corpus in 39.864
  seconds. All configured 250 ms search and 256 MiB memory budgets passed.
- Exercised V2 readiness, encrypted-store access, capture, normalized search,
  keyboard navigation, favorites, tags, filters, editing, self-write
  suppression, ignored-source settings, menu-bar reopen, and cleanup.
- Repeated the installed-app checks after switching from ad-hoc signing to a
  stable Apple Development identity. Keychain/store readiness and repeated
  installation passed without another signing authorization.
- Reinstalled once more and verified identifier `dev.bybee.AnyDoor`, Team ID
  `9VM4RM39R3`, and the Apple Development certificate chain before the final
  acceptance attempt.
- A one-second-spaced TextEdit sequence captured EVENT, A, and B exactly once in
  the expected newest-first order. An intentionally unpaced A/B/C sequence kept
  only C, so the real overwrite boundary remains uncharacterized.
- Deleted every record created by the GUI run and restored TextEdit's original
  ignored-source state. No unrelated history or preference was changed.
- The seventh Computer Use round could not start because the desktop automation
  service rejected the current node runtime as untrusted before exposing any UI
  state. No GUI action occurred. Its disposable Keychain was deleted, its
  profile was moved to Trash, and the normally configured installed app was
  relaunched.

## Found & fixed

- The installed app could block during SwiftPM resource-bundle resolution behind
  the Documents privacy boundary. `LocalizationManager` now resolves the
  packaged bundle from `Contents/Resources` before using `Bundle.module`.

## Still open

- Computer use changed the observed foreground source between AnyDoor and
  Ghostty even while driving a visible TextEdit document. This contaminates the
  same frontmost-application signal used by source attribution and exclusion;
  a physical TextEdit copy is required before treating the GUI result as a bug.
- Space failed twice with a visibly keyboard-selected text card in two separate
  rounds. The controller path and selection-model tests are valid, so one
  physical Space-key check is required before changing code.
- The deterministic 100/100 scheduler test observes after every simulated copy
  and does not measure the real pasteboard-overwrite boundary. The unpaced GUI
  sequence lost A and B, while one-second-spaced copies passed.
- Universal Clipboard behavior, multiple-display/Space behavior, and long-run
  sleep/wake or memory-pressure soak testing require external devices or elapsed
  wall-clock conditions that are not available in this run.
