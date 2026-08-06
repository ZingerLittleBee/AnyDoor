# testloop — 2026-08-06 — clipboard-history-v2

**Verdict:** stopped: physical-input confirmation remains for source attribution
and Space preview · **Rounds:** 6

## Covered

- Passed the first-party warning gate, 1,727 XCTest cases (5 skipped, 0
  failed), 33 Swift Testing cases, 225 clipboard-filtered cases (5 skipped, 0
  failed), mise-managed `pnpm verify`, and the arm64/x86_64 release build.
- Exercised V2 readiness, encrypted-store access, capture, normalized search,
  keyboard navigation, favorites, tags, filters, editing, self-write
  suppression, ignored-source settings, menu-bar reopen, and cleanup.
- Repeated the installed-app checks after switching from ad-hoc signing to a
  stable Apple Development identity. Keychain/store readiness and repeated
  installation passed without another signing authorization.
- A one-second-spaced TextEdit sequence captured EVENT, A, and B exactly once in
  the expected newest-first order. An intentionally unpaced A/B/C sequence kept
  only C, so the real overwrite boundary remains uncharacterized.
- Deleted every record created by the GUI run and restored TextEdit's original
  ignored-source state. No unrelated history or preference was changed.

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
