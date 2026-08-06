# testloop — 2026-08-06 — clipboard-history-v2

**Verdict:** stopped: two permission-dependent GUI cases and text preview remain unresolved · **Rounds:** 4

## Covered

- Validated the actual `feat/clipboard-history-v2` branch with the first-party
  warning gate, 1,727 XCTest cases (5 skipped, 0 failed), 33 Swift Testing cases,
  225 clipboard-filtered cases (5 skipped, 0 failed), and the 100/100 rapid-copy
  scheduler characterization.
- Ran `pnpm verify` through mise-managed Node 22 and pnpm 10.33.2, plus the
  arm64/x86_64 universal release build.
- Exercised the installed app in a disposable home and Keychain: V2 readiness,
  capture, normalized Unicode search, keyboard navigation, favorites, tags,
  filters, editing, self-write suppression, source-exclusion settings, and the
  menu-bar reopen path.
- Removed the disposable Keychain and moved its profile to Trash. The real
  application-support data was backed up before GUI testing and was not cleared.

## Found & fixed

- The default SwiftPM resource accessor could fall back from the installed app
  to the repository build directory and block startup behind the Documents
  privacy boundary. `LocalizationManager` now resolves the packaged resource
  bundle from `Contents/Resources` before using `Bundle.module`.

## Still open

- Space did not expose the floating text preview through computer use after the
  search field explicitly yielded focus to card navigation. The code path and
  model tests look valid, so this needs a physical-input confirmation before a
  code change.
- The ad-hoc installed identity had no Accessibility grant. The real rapid-copy,
  source-attribution, and live source-exclusion GUI checks therefore ran in the
  documented timer-only fallback and are inconclusive; the corresponding
  deterministic automated tests passed.
- Interactive approval of the existing production Keychain ACL was not run;
  the non-interactive cross-identity boundary test passed without modifying the
  encrypted store.
