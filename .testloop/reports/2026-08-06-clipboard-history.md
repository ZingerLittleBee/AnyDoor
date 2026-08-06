# testloop — 2026-08-06 — clipboard-history

**Verdict:** pass · **Rounds:** 4 plus manual physical-input confirmation

## Covered

- Verified the current branch at `ac4f73b`, which is identical to `main`, with
  `swift build --build-tests`, 1,598 passing Swift tests, 156 clipboard-focused
  tests, three repetitions of state-sensitive tests, the mise-managed
  `pnpm verify` gate, and an arm64/x86_64 universal release build.
- Exercised capture, normalized search, category and keyboard navigation,
  preview, favorites, tags, copy-back suppression, source exclusion/restoration,
  text editing, discard protection, and cleanup through the installed app GUI.
- Confirmed all test records, temporary tags, ignored-source settings, and
  unsaved TextEdit documents were removed; monitoring returned to its initial
  enabled state and unrelated history remained untouched.
- Measured targeted line coverage of 75.68% for AnyDoor clipboard model/services,
  96.29% for Image Conversion clipboard policy, and 3.68% for clipboard UI code.
- Repeated the source-attribution check with physical keyboard and mouse input;
  the history card correctly identified TextEdit as the source.

## Found & fixed

- None. No production code was changed during this verification run.

## Still open

- None. Computer use had attributed the controlled TextEdit copy to `Ghostty`,
  but the manual physical-input check correctly reported TextEdit. The earlier
  mismatch was a computer-use focus artifact rather than a reproduced product
  failure.
