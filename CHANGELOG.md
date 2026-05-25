# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

## [1.4.0] - 2026-05-25

### Added

- Window layout actions: four new built-in actions (left half, right half,
  maximize, center) that tile the frontmost window via Accessibility.
  `WindowLayoutService` resolves the focused window through AX, picks the
  screen with the largest overlap, and writes `kAXPosition`/`kAXSize`
  after converting Cocoa `visibleFrame` to AX coordinates. Failures
  (missing AX permission, no active window, full-screen window) surface
  as localized toasts instead of silent no-ops. Pure geometry is unit
  tested for clamping, odd widths, fractional frames, and exact-size
  edge cases.
- Window layout submenu: the four layout actions are grouped under a
  single `windowLayout` row, exposed as a hover popover from the menu
  bar and inline-expanded in Settings with drag-reorder + per-child
  hotkey binding. Children are hotkey-conflict-checked against the rest
  of the panel and snapshots refresh after reorder so global hotkeys
  follow the new order without a relaunch. A one-shot
  `windowLayoutDefaultsApplied_v1` backfill seeds the four children's
  `displayOrder` (2010/2020/2030/2040) so existing installs adopt the
  submenu without losing customizations.
- Keep Awake duration presets: the Keep Awake row gains a clock
  accessory with 15m / 30m / 1h / 2h / indefinite options backed by
  `IOPMAssertion`. Whole-row tap and the global hotkey still toggle
  indefinite to preserve muscle memory. The provider owns a single
  expiration `Task` so timers never stack or leak across re-applies;
  the hotkey path reads `await provider.currentState` instead of the
  MainActor cache so a press at the exact moment of expiration cannot
  invert the user's intent. Acquire failures resync the panel cache
  from the provider, and the "Awake until HH:mm" subtitle is
  re-formatted against `LocalizationManager.effectiveLocale` so a
  runtime language switch refreshes the rendered time.

### Changed

- `PanelRowView` reserves a fixed 18pt trailing accessory slot on every
  toggle row, so Keep Awake's new clock control aligns with the other
  switches instead of widening its trailing region.

## [1.3.1] - 2026-05-25

### Fixed

- Released `.app` crashed at launch with `unable to find bundle named
  AnyDoor_AnyDoor` because the SPM-generated resource bundle (produced by
  `.process("Resources")` for the String Catalog) was never copied into
  `Contents/Resources/`. `scripts/release.sh` now ditto-copies and
  separately codesigns `AnyDoor_AnyDoor.bundle` before signing the main
  binary. Same fix mirrored into `make install`, which additionally now
  copies `Sparkle.framework` and injects the `@executable_path/../Frameworks`
  rpath so a fresh `/Applications/AnyDoor.app` launches without relying on
  leftovers from a previous release build.

## [1.3.0] - 2026-05-24

### Added

- Status item right-click menu with Settings and Quit entries, bridged
  to SwiftUI's `\.openSettings` so the Settings window opens through
  the same path as the in-panel button.

### Changed

- Menu bar panel footer redesigned: a divider separates it from the
  content, and Settings / Quit are now compact icon-only buttons with
  tooltips, reducing the visual weight of bottom chrome.

### Fixed

- Brightness +/− hotkey recorder labels in Settings now use the
  existing `builtin.brightnessUp/Down` localizations instead of
  hard-coded Chinese strings.
- Clipboard history hint chips ("Space", "Preview") no longer wrap to
  two lines in English locales.

## [1.2.0] - 2026-05-24

### Added

- Generated clipboard history: outputs produced by built-in actions
  (QR code recognition, screenshots, and similar generators) are now
  recorded into a dedicated SwiftData-backed history store. Screenshot
  payloads are persisted to disk; text payloads are kept inline.
- History popover: hovering an action row reveals a side popover
  listing recent generated outputs, with a selection model, keyboard
  navigation routed through a first-responder NSView, and a header
  hint surfacing the active shortcuts.
- Screenshot preview: selecting a screenshot entry opens it in a
  dedicated floating panel sized to 60% of the screen, with a top-right
  close button. The panel is configured to appear correctly under the
  `.accessory` activation policy.
- Settings: a "清空历史" action to wipe all generated history at once.

### Changed

- Action rows in the hover popover now display a chevron affordance to
  indicate that further content is available on hover.

### Fixed

- Hover gate no longer collapses when the cursor crosses between rows
  or moves from a row into the popover itself, keeping the popover
  stable during normal mouse movement.
- `clearAll` now consistently resets the in-memory cache and
  `lastPrunedAt` watermark so subsequent reads reflect the cleared
  state.

## [1.1.0] - 2026-05-24

### Added

- QR code recognition: drag-select a screen region to decode any QR codes
  inside it. Payload is copied to the clipboard verbatim; multiple codes
  are newline-joined top-to-bottom. The toast reports status only and
  never includes the decoded content. New "识别二维码" panel row with an
  assignable global hotkey.

### Changed

- Removed the user-tunable update-check frequency setting; Sparkle now
  uses its default schedule.

## [1.0.1] - 2026-05-23

### Fixed

- App failed to launch from `/Applications` because the bundled
  `Sparkle.framework` was not on dyld's search path. The release script now
  injects `@executable_path/../Frameworks` into the main executable's rpath
  before codesigning.

## [1.0.0] - 2026-05-23

### Added

- Auto-update via Sparkle 2 with assets published to GitHub Releases.
- "关于与更新" section in General settings.
- Menu bar panel banner when a new version is available.

### Changed

- Lowered the minimum supported macOS version to 14.0 (Sonoma) while keeping
  Liquid Glass effects on macOS 26+ only. OCR now uses the legacy
  VNRecognizeTextRequest path, and Settings falls back to the classic
  TabView/tabItem API.

## [1.0.0] - 2026-05-23

- Initial release.
