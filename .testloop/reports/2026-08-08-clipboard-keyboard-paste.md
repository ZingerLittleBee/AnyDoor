# testloop — 2026-08-08 — clipboard keyboard and paste

**Verdict:** stopped: Space behavior remains inconsistent under Computer Use ·
**Rounds:** 2 (campaign rounds 8–9)

## Covered

- Used disposable application data, an acceptance Keychain, and temporary
  TextEdit documents; production clipboard history was not touched.
- Captured one Unicode TextEdit marker exactly once, found it through indexed
  search, and confirmed the visible source was TextEdit.
- Space preview opened and closed successfully in round 8. The same action had
  no visible effect twice in round 9, despite a selected card and an otherwise
  responsive wall.
- Reproduced an Enter-paste failure in round 8, then verified the destination
  received the exact Unicode marker immediately after the fix in round 9.

## Found & fixed

- The wall restored its destination with `NSRunningApplication.activate()`,
  which macOS 14+ may ignore when called by an accessory app. The wall now uses
  Launch Services before synthesizing Command-V in
  `Sources/AnyDoor/Views/ClipboardWallWindowController.swift`.

## Still open

- Computer Use produced conflicting Space-preview results across independent
  runs. The controller and selection-model paths pass automated tests, so one
  physical Space-key confirmation remains before changing preview code.
- Universal Clipboard, multi-display behavior, and long-duration soak coverage
  still require external devices or elapsed wall-clock conditions.
