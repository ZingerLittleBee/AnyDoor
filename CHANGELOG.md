# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

### Added

- Hosts management: create, edit, delete, and activate named host profiles and
  apply the merged result to `/etc/hosts`. A new `hostsManager` built-in opens
  a hover popover for quick activation toggles plus a single button into a
  master-detail editor window. Writes go through a privileged helper
  (`SMAppService` LaunchDaemon over XPC) so the user authorizes once and writes
  are password-free thereafter; ad-hoc/dev builds fall back to an
  AppleScript admin-prompt writer. The helper validates every caller by audit
  token (`SecCodeCopyGuestWithAttributes` + code-signing requirement, closing
  the PID-recycling window), caps the payload, serializes writes, and replaces
  `/etc/hosts` atomically (temp file in `/etc` → fsync → root:wheel 0644 →
  rename). `HostsManager` is the single source of truth: it composes a marked
  managed block between sentinel comments while preserving the system content
  before and after it verbatim, applies first and persists only on success
  (rolling back from the store on failure), debounces and serializes rapid
  activation toggles into one consistent write, and skips the privileged write
  entirely when the result would be unchanged (so toggling or deleting a blank
  profile never prompts for authorization). System Hosts is editable in the
  window — saving rewrites the system portion while preserving the managed
  block — and the editor opens in read-only view mode by default, requiring an
  explicit 编辑 to enter edit mode and resetting to view mode when switching
  files, to prevent accidental writes. Profiles can be deleted from the detail
  pane, a right-click menu, or the Delete key, and Return toggles activation
  for the selected profile. A one-time backup of the original `/etc/hosts` is
  captured before the first managed write and surfaced as a confirmed
  "恢复首次备份" recovery; an in-app banner deep-links to System Settings when
  the helper awaits approval.

### Fixed

- Command Palette stuttered on the first scroll, then ran smoothly afterwards.
  `CommandPaletteRow` resolved its Finder icon via `NSWorkspace.icon(forFile:)`
  inside `body` — a synchronous disk read on every body pass with no caching —
  so when `LazyVStack` materialized a fresh batch of rows on the first scroll,
  each row hit disk in the same frame and dropped frames; reused rows never
  re-ran, so later scrolling stayed smooth. The icon is now loaded once per row
  in a `task` and cached in `@State`, leaving `body` a pure in-memory read. This
  is the twin of the 1.8.2 `SpotlightRow` fix, which missed the command palette
  row.

## [1.8.2] - 2026-06-02

### Fixed

- Spotlight app picker pinned a CPU core to 100% when left open. The search
  field re-focus handler reasserted focus on every runloop tick whenever the
  system refused to return first-responder (a SwiftUI focus / AppKit
  first-responder desync, e.g. the floating panel sitting on another Space):
  each failed attempt fired the change handler again, never settling. The
  handler now gives up after a few consecutive failed strikes and resets the
  counter once focus is genuinely regained, so a stray hit-test still reclaims
  focus once but a desync can no longer spin. The loop was amplified by two
  per-frame costs, now removed: `filteredApps` re-scanned every installed app
  on each of its several reads per render (now memoized behind an
  observation-ignored cache over a precomputed pool), and each row resolved its
  Finder icon via NSWorkspace on every body pass (now resolved once per row in
  a task).

## [1.8.1] - 2026-06-02

### Added

- Window layout: the Window Layout submenu gains 13 new actions — top and
  bottom halves, four quarter-screen corners, left/center/right thirds,
  left/right two-thirds, and move-to-next / move-to-previous display. Each is
  an independent, individually hotkey-bindable item. Tiling actions tile the
  visible region exactly (the center third absorbs rounding so columns never
  gap or overlap); display moves remap the focused window proportionally onto
  the neighboring screen, ordered left-to-right with wrap-around, and surface a
  toast when only one display is connected.

## [1.8.0] - 2026-06-01

### Added

- Clipboard history: a Paste-style clipboard manager. A background
  `ClipboardWatcher` polls the pasteboard and `ClipboardCapture` classifies
  each copy into text, image, or file references, persisting them through
  `ClipboardHistoryStore` (SwiftData). A bottom card wall, summoned by ⌘⇧V via
  the `ClipboardWallWindowController`, presents the history as a horizontally
  scrolling card wall with category tabs for all / text / image / file plus the
  existing screenshot, color, OCR, and QR-code histories, and live search over
  the timeline. Search matching lives in a pure, unit-tested `ClipboardSearch`:
  it tokenizes the query on whitespace and requires every token to appear (AND
  semantics) against the entry's content only — title, full text, color hex,
  and file names, never the metadata subtitle — and folds case, diacritics, and
  width so "cafe" finds "café" and "1234" finds "１２３４". The search field is a
  real focusable `NSTextField` (`WallSearchField`) so an input method editor can
  compose CJK queries, with two keyboard modes: card navigation (arrows select,
  Enter pastes, Space previews, typing focuses the field) and input (the field
  owns text editing and IME; → at the end of a non-empty query hands focus back
  to card navigation). Esc stages the exit — a non-empty query clears, an empty
  query closes the wall. Selecting a card pastes into
  the frontmost app — rich paste by default, plain-text paste with ⌥↵ — driven
  by `ClipboardPasteService` (`writePayload`/`synthesizePaste`); items can be
  favorited, deleted, or previewed inline with Quick Look (space). Retention is
  configurable in Settings → General; the prune pass exempts favorites so
  starred entries survive the retention window. The watcher honors privacy
  rules (transient/concealed pasteboard types are skipped) and a per-item size
  ceiling, and `noteSelfWrite` suppresses re-capturing the app's own paste
  writes. Deferred for now: the app-exclusion list editor and disk-budget UI —
  the preference keys exist and the watcher already honors them, only the
  editor surfaces are pending. Backups deliberately exclude clipboard history
  (see config sync below).
- Config sync: back up and restore configuration to/from a JSON file from
  Settings → General → 备份与恢复. The export gathers app shortcuts
  (`KeyBinding`), builtin preferences (`BuiltinPreference`), and a whitelisted
  set of general settings (`SyncSettingsRegistry`) into a Codable
  `BackupSnapshot`; clipboard history and machine-specific keys
  (`hyperKey.ownedSignatures`, `PortInventory.viewMode`, `SUSkippedVersion`)
  are deliberately excluded. Storage sits behind a `SyncBackend` protocol so
  iCloud/Gist/S3 backends can be added later; the first backend is a local
  file via NSSavePanel/NSOpenPanel. Import merges per key — app shortcuts by
  `appBundleID`, builtin preferences by `itemKey` — with imported values
  winning and local-only rows preserved; unknown preference keys are skipped.
  `appPath` is never serialized and is re-resolved locally from the bundle ID
  on import (via `NSWorkspace`), so backups stay portable across machines with
  different usernames. After import, `reconcileAfterImport` re-reads the
  affected settings into `CommandPaletteService`, `LocalizationManager`, and
  `HyperKeyService` and rebuilds the hotkey snapshots, so imported hotkeys,
  language, and menu-bar icon take effect without a relaunch.
- Command Palette: port-number searches now surface matching listening
  processes in a dedicated Ports section. Port process rows are omitted while
  the query is empty, and selecting a port row kills the owning PID through
  the existing Port Manager flow with a success or failure toast.

## [1.7.0] - 2026-05-28

### Added

- Command Palette: every installed app on the system is now searchable, not
  just apps the user explicitly bound to a hotkey. `CommandPaletteWindowController`
  scans via `InstalledAppsScanner` when the palette opens, filters out bundle
  IDs already represented by an app-shortcut row, and appends the remaining
  apps to the Applications section after the bound rows. Selecting one routes
  through `AppSwitcher.toggle`, identical to the bound-shortcut path. A new
  `PanelEntry.Source.installedApp(bundleID:path:)` variant carries the
  necessary data; it is command-palette-only and never surfaces in the menu
  bar panel or settings UI.
- Command Palette: sticky section headers. The Applications / Window Layout /
  Commands labels stay pinned to the top of the scroll viewport as their rows
  scroll past, matching the Raycast feel. Rows share the pinned header's
  material layering on macOS < 26 so the header/row boundary has no visible
  double-material seam. Arrow-key navigation now compensates for the pinned
  header: moving up scrolls to the row above the target so the target lands
  one row below the sticky band instead of hidden behind it, and a 0-height
  top sentinel anchors the `newIndex == 0` case so the first section header
  lands naturally above row 0 instead of pinning over it.

### Changed

- Menu bar panel: dismiss on Escape. The panel is a non-activating `NSPanel`
  so a SwiftUI `keyDown` handler would never fire; a global + local
  `NSEvent` monitor is now installed while the panel is visible so Escape
  closes it whether AnyDoor or another app is frontmost.
- Menu bar panel header removed. The AnyDoor title was redundant with the
  status item icon, and the `%lld enabled` count was low-value noise on
  every open. Dropping the header HStack also removes its now-orphaned
  localization entries.
- Menu bar panel footer removed. The Settings gear and Quit power icons
  sat 2pt apart and were easy to mis-tap; both actions are already exposed
  via the status item's right-click menu with the standard ⌘, and ⌘Q
  shortcuts.
- Command Palette adopts Liquid Glass on macOS 26+. Two new helpers in
  `LiquidGlassCompatibility` — `adaptivePanelSurface(cornerRadius:)` for
  non-interactive panel backgrounds and `adaptiveStickyHeaderSurface()` for
  full-width pinned headers — apply `.glassEffect(.regular, in:)` and
  `.background(.thinMaterial)` respectively, with `.thickMaterial` fallbacks
  on earlier systems. The outer palette becomes one Liquid Glass surface so
  the search field, rows, and headers read as a single material; per-row
  `.thickMaterial` is dropped on macOS 26 to avoid double-layer composites
  that previously made the list area look noticeably darker than the search
  field. The sticky header uses `.thinMaterial` — heavy materials or a
  nested `glassEffect` rendered as a dark opaque strip that broke the
  design language.
- Command Palette row icons: SF Symbols dropped from 18pt to 15pt so they
  read at the same visual weight as the NSImage app icons, which carry
  built-in transparent padding the symbols lacked.

## [1.6.0] - 2026-05-27

### Added

- System apps in App Shortcuts: Finder, System Settings, Calculator, and other
  built-ins from `/System/Applications` or `/System/Library/CoreServices/Finder.app`
  can now be bound to global hotkeys. A new `InstalledAppsScanner` enumerates
  `/Applications`, `/System/Applications`, both `Utilities` subdirs, and
  `~/Applications`, plus an explicit probe for Finder. The previous
  `NSOpenPanel` (locked to `/Applications`) is replaced by a Spotlight-style
  floating picker — borderless rounded `NSPanel` positioned near the top of
  the active screen with a thick-material background, a large search field,
  single-click selection, click-outside / Esc dismissal, and already-bound
  apps automatically filtered out. Arrow keys move the highlighted row,
  Enter selects, and a panel-level `NSEvent` key monitor intercepts arrow /
  Return / Escape before the focused `TextField` can consume them so the
  search input stays the keyboard target throughout.
- Command Palette: a global launcher-style panel that surfaces every directly
  invocable menu bar item — built-in toggles/actions, window-layout children,
  and visible app shortcuts — grouped into labelled sections (Commands /
  Window Layout / Applications) with uppercase muted headers. Configurable
  trigger hotkey lives in Settings → General → Command Palette and is stored
  via `CommandPaletteService` (UserDefaults); the snapshot is threaded into
  `PanelStore.rebuildHotkeySnapshots` so the CGEvent tap picks it up without
  a relaunch. Re-pressing the trigger while the palette is open dismisses it,
  matching macOS Spotlight. Selection routes through `PanelStore.dispatch`,
  so app rows toggle their target app and built-ins fire their normal
  toggle / run path. Section headers are wrapped into each row's `id` bounds
  so `ScrollViewReader` brings the label and row into view together when
  navigating across groups, and `safeAreaInset` keeps an 8pt visual gap at
  the top and bottom edges so the highlighted row never touches the panel
  border.

### Fixed

- Settings → 面板: the Display Brightness sub-row hotkey recorder now lines
  up with the Window Layout sub-row recorders along the panel's right edge
  (was missing the 20pt trailing inset that the layout rows used).

## [1.5.0] - 2026-05-27

### Added

- Hyper Key: pick a single physical key (Caps Lock, left/right modifier, or
  F1–F12) and have it generate the `⌃⌥⌘` (or `⌃⌥⇧⌘`) combination, providing
  a conflict-free shortcut layer.
  Configured in Settings → General with a green dot indicating the mapping
  is live. Shortcuts bound to the Hyper combo render as `✦Key` in the
  recorder, panel, and conflict alerts. `hidutil` remaps the trigger to a
  reserved F19 (keyCode 80); the existing CGEvent tap maintains a
  `hyperHeld` state machine, augments companion `keyDown` events with the
  hyper modifier mask, suppresses the corresponding `keyUp`, and skips
  Quick Press on a held release. A Quick Press picker chooses what a solo
  tap does: nothing, Escape, or the trigger's original key (Caps Lock toggle
  is emitted via `IOHIDPostEvent` to bypass our own sentinel-tagged tap).
  Launch is split into an unconditional `reconcile` (only removes our own
  hidutil residue, requires no permission) and a tap-gated `apply`, so a
  crash + revoked Accessibility combo can never leave the user's keyboard
  bricked. A 2-second watchdog observes tap health; emergency-clear paths
  are token-guarded against concurrent `setTrigger` so a stale revert
  cannot overwrite a fresh apply.
- Hotkey recorder: pressed modifiers now render live while recording
  instead of only appearing at commit time, and the Hyper trigger (when
  configured) acts as a modifier in the recorder — pressing it shows ✦,
  pressing it + a letter commits the combo as `✦Key`. Trigger detection
  routes through the existing HotkeyService tap rather than suspending it,
  because Caps-Lock-sourced F19 doesn't always survive a disabled tap on
  every macOS build. The tap stays active in a "recording" mode that
  suppresses bound-hotkey dispatch and Quick Press while still reporting
  `hyperHeld` to the recorder; the recorder reads the authoritative
  `isHyperHeld` synchronously at commit time so an async observer dispatch
  cannot drop ✦ folding.

### Fixed

- App activation: switching to another app via a hotkey now routes through
  `NSWorkspace.openApplication` (Launch Services) instead of
  `NSRunningApplication.activate()`. On macOS 14+ the latter is silently
  ignored when called from an `.accessory` app while a regular app holds
  keyboard focus, so a hotkey pressed inside e.g. Warp would toggle the
  current app via `hide()` (no activation right required) yet do nothing
  when targeting a different app. The Launch Services path inherits user
  activation rights and matches the route other launcher apps use.
- Settings: newly added app rows render an empty hotkey recorder showing
  the placeholder text instead of literal `Key(-1)`. The sentinel `-1`
  keyCode used to flag "not yet bound" now projects to a `nil`
  `HotkeyDescriptor` in the panel, so the recorder picks its unbound
  branch.

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
