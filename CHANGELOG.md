# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

### Added

- Command palette: inline unit, time-zone, and currency conversion. Typing a
  conversion expression surfaces a Conversion section with the answer on top;
  Return copies the value with a content-free toast. Units cover length, mass,
  temperature, data size (decimal and binary), and speed via `"<n> <unit> to/in
  <unit>"` (e.g. `3 ft to m`, `72 f to c`, `1 gb to mib`). Time zones handle
  `"<time?> <place>"` and `"<time?> <a> to <b>"` (e.g. `3pm tokyo`, `9am london to
  tokyo`, `tokyo time`) with a curated city map, a `GMT±H` label, and a day-offset
  marker when the wall date crosses midnight. Currency converts `"<amount> <code>
  to <code>"` (plus `$`/`€`/`£` symbols) against a rate table cached from
  Frankfurter (ECB data, key-free) — fetched at most once per day, used offline
  from the last cache with an "as of <date>" subtitle. Each converter is a pure,
  total facade mirroring the calculator; detection requires a recognized
  unit/currency/place plus a connector or time token, so ordinary command and app
  search is untouched.
- Command palette: inline developer tools. Typing a keyword surfaces instant,
  copy-on-Return conversions — `base64` (encode + decode), `url` (percent-encode +
  decode), `md5` / `sha1` / `sha256` hashes — plus two auto-detected tools that need
  no keyword: paste a JSON object or array for pretty / minified output (keys sorted),
  or a 10-digit (seconds) or 13-digit (milliseconds) Unix epoch for local / UTC /
  ISO 8601 renderings. The core is a pure, total `DevTools` facade mirroring the
  calculator; explicit keywords plus strong-signal auto-detection keep bare words and
  short numbers in normal app/command/port search. Pressing Return copies the result
  and confirms with a content-free toast, since hashes and multi-line JSON make poor
  toast bodies. A Raycast-style scope badge makes the keyword tools first-class:
  typing a keyword + space, or Tab on a bare keyword, absorbs it into a search-bar
  pill (Base64 / URL / MD5 / SHA-1 / SHA-256), drops the keyword from the field, and
  makes the list exclusive to that tool; Backspace on an empty body sheds the badge,
  and Esc escalates (clear body → shed badge → dismiss). While a keyword prefix is
  still being typed the palette suggests the matching tool(s) on top, selected by
  default so Return enters the scope; once inside a tool with nothing typed yet, the
  panel shows a usage hint and a worked example instead of the generic "no matches"
  state.
- Command palette: hosts profiles are reachable by name from the root. Typing a
  profile name surfaces a Hosts section whose rows toggle that profile's activation
  on Return, mirroring the existing port direct-search. Activation goes through the
  same path as the drill-in toggle (it may still prompt for the privileged write),
  and no per-profile global hotkey is introduced, so a stray keystroke can't trigger
  an admin prompt.
- Color picker output format: the picked color can be copied as HEX, RGB, HSL,
  SwiftUI `Color`, or lowercase CSS hex. The format is chosen from the command
  palette's Pick Color second-level menu, persists as the default for every pick path
  (menu-bar row and global hotkey), and rides settings backup. A pure `ColorFormat`
  renders the sampled `#RRGGBB` value into each representation; color history still
  stores the raw hex.
- System microphone mute: a new panel toggle mutes / unmutes the default input device
  via CoreAudio, giving a conferencing-app-independent mic switch with the usual
  panel row, global hotkey, command-palette entry, and backup wiring. Devices that
  expose no settable mute (some built-in mics, AirPods in the input scope) surface a
  toast and leave the row state unchanged instead of failing silently.
- App Shortcuts menu-bar popover now shows a hint guiding the user to add shortcuts in
  Settings when none are configured, instead of an empty list.

## [2.3.1] - 2026-06-13

### Added

- Clipboard history gains two menu-bar panel controls: a Clear Clipboard action
  that empties the current pasteboard without recording the clear as history, and
  a Clipboard Monitoring toggle that uses the same setting as General Settings.
  The clipboard wall can also filter entries by source app and lets a card's
  source app be added to the ignored-source list directly from the card menu.
- Port Manager rows now offer a context menu for copying the port, PID, command,
  or `localhost` URL, and can open the matching `http://localhost:<port>` address
  directly.
- Hosts profiles can be duplicated from the editor. Duplicates start inactive,
  get a collision-safe copy name, are selected immediately, and enter inline
  rename so the copy can be renamed in place.
- Hosts profile rows now expose enable/disable in their context menu, with
  in-row loading feedback while the profile activation write is in progress.

### Changed

- Hosts profile management keeps activation as the first context-menu action,
  styles the active profile's Disable action as destructive, and keeps duplicate
  / delete actions in the editor instead of the menu-bar popover.
- The Hosts editor now shows Cancel next to Save while editing. Cancel discards
  the draft and returns to the current persisted hosts content.

### Fixed

- The Hosts editor no longer shows the titlebar overflow `>>` button caused by
  an extra Delete toolbar item being collapsed into the window toolbar overflow.
  Deletion remains available from the detail-area Delete button, profile context
  menu, and Delete / Backspace key handling.
- Hosts profile row selection no longer competes with double-click rename
  gestures. Rename stays available from the profile context menu, and rows keep
  a full-width hit target for reliable selection.
- Scheduled Shutdown no longer flashes a red "missed" toast at seemingly random
  times. A shutdown timer only fires while AnyDoor is running, so a deadline that
  lapses while the app is not running was never going to run — yet `bootstrapOnLaunch`
  still surfaced it as a `.failure` toast on the next launch. Because the app
  relaunches for reasons the user doesn't notice (silent Sparkle auto-update
  relaunch, login auto-start), this flashed a "Scheduled … failed"-looking toast
  even after the app appeared to be quit or untouched. `applicationWillTerminate`
  now records a `scheduledShutdown.cleanExit` marker (consumed unconditionally on
  the next launch), so a deadline missed across a clean Quit / update relaunch /
  restart is cleared silently; only a genuine crash-induced miss shows a toast,
  now informational (`.info`, not `.failure`) and held long enough to read. Future
  deadlines still survive relaunch as before.
- Relaunching AnyDoor no longer waits out Sparkle's update cadence before it
  notices a newer version. `SPUStandardUpdaterController(startingUpdater:)` only
  schedules interval-gated background checks (24h here) keyed off the persisted
  last-check time, and the app never triggered a check itself — so a version
  published between the last scheduled check and the next one stayed invisible
  across relaunches. `bootstrapUpdater()` now forces a single silent
  `checkForUpdatesInBackground()` right after starting the updater (guarded on
  automatic checks being enabled, the only point Sparkle's API sanctions a manual
  background check), so a relaunch surfaces a newer version immediately. Results
  still flow through the delegate into `UpdateService.availableVersion`, so the
  existing in-panel banner shows it with no extra Sparkle UI and user-skipped
  versions remain suppressed.

## [2.3.0] - 2026-06-13

### Added

- Clipboard history can now ignore items copied from selected source apps.
  Settings → General → Clipboard lists ignored apps, reuses the app picker for
  adding entries, and stores the exclusion list by bundle id so the watcher can
  skip matching pasteboard changes before they enter history.
- Backup and restore now include the clipboard ignored-app list, so source-app
  exclusions move with the rest of the portable settings.

### Fixed

- Settings no longer opens on login auto-launch. The reopen handler now keys on
  the menu-bar icon: while the icon is visible the user can always open Settings
  from it, so a reopen never auto-pops Settings. The previous launch-age window
  was unreliable — under a busy login the reopen Apple Event can arrive seconds
  after launch and was misread as a user relaunch. Settings still surfaces on a
  genuine relaunch when the icon is hidden (the recovery path).

## [2.2.0] - 2026-06-12

### Added

- Clipboard wall: user-defined categories. Right-click a card → "Add to
  Category" tags it — the submenu lists every category with a checkmark for
  membership (an item can carry several tags) plus an inline "New Category…";
  custom tabs appear after Favorites and are renamed or deleted from their own
  right-click menu. Tagged items are exempt from automatic cleanup, exactly
  like favorites; deleting a category keeps its items and only restores normal
  retention, after a confirmation since that exemption is what's being given
  up. Create / rename / delete-confirm run as a modal card inside the wall
  window rather than an `NSAlert`, which would steal key status and trip the
  wall's resign-key dismissal — while it's up, Return commits and Esc cancels
  (both deferring to an active IME composition), the dimmer click cancels, and
  card scrolling / right-click menus are suppressed; opening a dialog while
  the floating text panel shows first dismisses it, routing a dirty editor
  through its discard confirmation instead of dropping the edit. Category
  definitions live in UserDefaults and ride along in settings backup
  (export/import), with imports pruning tag ids that no longer resolve. On
  the model, membership is persisted as an optional JSON string scalar rather
  than a `[String]` transformable, so SwiftData lightweight migration leaves
  legacy rows readable instead of crashing the first fetch after update.
- Clipboard wall: a Favorites tab between "All" and the kind tabs shows only
  starred entries, and favorites now survive in the timeline past the
  retention cutoff (they were exempt from pruning but the wall's time filter
  still hid them). The card-footer star button is gone — favoriting moved to
  the right-click menu — and favorited cards instead show a passive star badge
  in the header.
- Clipboard wall: Tab / Shift-Tab cycles through the category tabs (wrapping,
  custom tabs included), scrolling the active capsule into view when the tab
  row overflows.
- Clipboard wall: hold ⌘ to enter a Launchpad-style tab edit mode — the
  category capsules jiggle (neighbors out of phase, the macOS "movable now"
  signal) and gain a dashed outline, custom tags sprout a steady top-right ✕
  badge that opens the existing delete confirmation (which spells out that
  the category's items are kept, only their cleanup exemption ends), and
  dragging a capsule reorders the row: the dragged tab lifts (scaled,
  shadowed) and follows the pointer while the others shift aside live toward
  the projected drop slot, committing on release. The wiggle is driven by a
  phase state scoped to the rotation alone — hanging a repeat-forever
  `.animation` on the capsule would also capture the drop-slide into the new
  slot and leave a moved tab oscillating between its old and new positions —
  and each capsule's swing direction keys off its stable category
  id, not its current index, so a reorder can't flip a running animation's
  target. The order persists (and rides settings backup) as a list of stable
  category ids, so deleting a tag drops only its entry while newly created
  tags append at the end. Everything is ⌘-gated, so plain clicks, right-click
  tab menus, and the row's horizontal scrolling are untouched; the wall
  footer hints the mode ("⌘ 按住编辑分类").
- Clipboard wall: file cards gain a "Reveal in Finder" context-menu item. It
  prefers the file's original path and falls back to the copy stored in the
  history directory when the original is gone.
- Clipboard wall: pressing Space on a text-bearing card (text / OCR / QR code)
  now opens a floating read-only text preview — the "space 预览" hint in the
  wall footer previously did nothing for text. The preview mirrors the
  screenshot preview panel (borderless, non-activating, never key, centered at
  60% of the screen), follows the keyboard selection like Finder Quick Look
  (arrows and the scroll wheel move cards while the preview content swaps in
  place; landing on a non-text card closes it), closes on Space / Esc / any
  outside click, and shows the card's line/character count in its footer.
  Pressing `E` — or the edit button next to the preview title, which doubles
  as the shortcut hint — swaps the preview for the editor on the same item.
  Image, screenshot, and file cards keep system Quick Look; color keeps none.
- Clipboard wall: cards gain a right-click context menu — Edit (text-bearing
  kinds only), Copy, Favorite/Unfavorite, and Delete. The menu is a native
  NSMenu served through NSView's `menu(for:)` from a transparent overlay that
  claims only right-/control-clicks (taps, double-click paste, and hovers pass
  through), because SwiftUI's `.contextMenu` bridge flash-resizes item icons
  when the menu opens on macOS 26. Copy writes the payload back to the
  pasteboard without pasting or dismissing the wall, suppresses the watcher's
  self-capture, and confirms with a toast. Edit opens a floating plain-text
  editor (the hosts module's monospaced, undo-capable `PlainTextEditor`) on a
  key-capable non-activating panel: ⌘S or the Save button persists the change
  (whitespace-only content disables Save at both the UI and the store), and
  Esc / Cancel with unsaved changes shows an in-panel discard confirmation
  instead of silently dropping the edit — the wall hotkey and switching to
  another item are guarded the same way, a stray outside click never closes
  the editor, and a no-change save is skipped so it cannot destroy the item's
  rich payload. Saving rewrites the card's preview title/subtitle and clears
  the now-stale rich payload, so pasting the item afterwards produces the
  edited plain text rather than resurrecting the original rich content, while
  the item's timestamp is preserved so the card keeps its position. The wall
  stays open behind both panels: its resign-key handler, outside-click
  monitor, and scroll-wheel card navigation all exempt them, and scrolling
  over the panel scrolls its text instead of flipping cards.

## [2.1.1] - 2026-06-12

### Fixed

- Screen Text Recognition and QR-code scanning now explicitly request macOS
  Screen Recording access before launching the interactive capture flow, and
  show a permission-specific toast when access is denied instead of silently
  behaving like the selection was cancelled. OCR recognition also covers
  Traditional Chinese (`zh-Hant`) with Vision language detection enabled.

## [2.1.0] - 2026-06-08

### Added

- Command palette: option-bearing commands now open a keyboard-navigable
  second-level menu instead of acting with a default. Selecting Keep Awake,
  Scheduled Shutdown, Brightness, Hosts, or Port Manager drills into that
  command's options (Raycast-style push) — a back header shows the parent and
  Return runs an option and dismisses. Esc clears a non-empty search first;
  with an empty search it returns to the root from the second level or closes
  the palette at the root (an empty-query Backspace or clicking the header also
  returns to the root). The second level itself is searchable (matching both
  titles and subtitles, so typing a port number narrows the port list). Keep Awake and Scheduled Shutdown mirror their panel
  duration presets (15 / 30 / 60 / 120 min, indefinite, plus a destructive Turn
  Off / Cancel only when active); Brightness lists 0 / 25 / 50 / 75 / 100 %
  steps applied to every external DDC display and appears only when one is
  present; Hosts lists each profile with an active checkmark (selecting toggles
  it, which may prompt for admin authorization on the privileged write) plus an
  always-present "Edit hosts…" that opens the editor window; Port Manager lists
  every listening TCP port (process name with a port · pid subtitle). Killing a
  port — from either the drill-in or the root numeric search — now asks first
  with a Raycast-style in-palette confirmation card (Return confirms, Esc
  cancels), so a stray keystroke can't terminate a process; on confirm it kills
  with the usual toast. A new `CommandPaletteOptions`
  (`@MainActor`) is the single
  source of truth for which builtins are option parents and their options, with
  pure per-item builders that take already-fetched state (`isOn` / `isArmed` /
  `displays` / `profiles` / port records) so they unit-test without singletons;
  each option's action runs through the existing services (`setKeepAwakeDuration`
  / `setScheduledShutdownDuration` / `DisplayBrightnessService.setBrightness` /
  `HostsManager.setActive` / `PortInventory.kill`) so the palette and the panel
  never drift. Option rows reuse the existing list/row rendering via a new
  command-palette-only `PanelEntry.Source.paletteOption(id:)` (a `String` id, the
  action looked up on the MainActor), and `CommandPaletteState` gains a root ⇄
  options navigation stack. App Shortcuts and Window Layout keep their existing
  flat, directly-searchable sections, and typing a port number at the root still
  surfaces a Ports section for a quick kill — alongside the new Port Manager
  drill-in, ports stay reachable both ways.
- Scheduled Shutdown: arm a one-shot countdown to shut the Mac down from the
  menu-bar panel, with a cancelable pre-fire warning, graceful (default) or
  optional forced shutdown, and the schedule surviving relaunch.
- Emptying the Trash now reports its outcome with a bottom-center toast,
  matching the other quick actions (pick color, OCR, port kill). It shows a
  success message when the Trash is cleared, a distinct hint when the Trash is
  already empty, and a permission prompt when Automation access is denied.
  Dismissing Finder's confirmation dialog is treated as an intentional no-op
  and stays silent.

### Changed

- The menu-bar panel height cap is now a proportion of the usable screen height
  (80%) instead of a fixed 8pt margin, leaving more breathing room on tall
  displays. Overflow still scrolls inside the panel.
- External-display brightness on Intel Macs now uses MonitorControl's
  MIT-licensed `IntelDDC`, vendored into the app, instead of the upstream
  `reitermarkus/DDC.swift` dependency, which ships with no license. The DDC/CI
  behavior is unchanged; Apple Silicon continues to use the existing
  `Arm64DDCBackend`. Bundled third-party license texts are now collected in
  `THIRD-PARTY-LICENSES.md`.

### Fixed

- Triggering Empty Trash on an already-empty Trash surfaced a spurious failure.
  Finder returns `-128` both for that case and when its confirmation dialog is
  cancelled; the empty case is now short-circuited before the AppleScript call
  and the cancelled case is handled silently.

## [2.0.2] - 2026-06-05

### Fixed

- The Settings window reopened on its own whenever AnyDoor auto-launched at
  login. macOS state restoration was reopening the previous session's window,
  but AnyDoor is a menu-bar utility where no window should appear unbidden. The
  app now opts out of application state restoration
  (`application(_:shouldRestoreApplicationState:)` and `shouldSaveApplicationState`
  return `false`) and additionally marks the Settings window non-restorable as a
  fallback for the per-window restoration path. Settings still opens on demand
  from the menu-bar item.
- The menu-bar panel could run off the bottom of the screen once enough items
  were enabled, leaving the lower rows unreachable. The panel height is now
  capped to the usable screen height; any overflow scrolls inside the panel
  (`NSScrollView` wrapping the measured hosting view, with rounded-corner
  clipping preserved). Hover sub-popovers (App Shortcuts, Port Manager,
  brightness, clipboard history) re-anchor correctly as the list scrolls.

## [2.0.1] - 2026-06-04

### Fixed

- Command Palette still stuttered on the first scroll into the Applications
  section, despite the 1.9.0 fix. That fix moved `NSWorkspace.icon(forFile:)`
  out of `body` into a `task`, which stopped the per-body-pass re-resolution
  but not the stutter: a SwiftUI `task` closure inherits the view's `@MainActor`
  isolation, so the synchronous disk read still ran on the main thread — and
  when `LazyVStack` materialized a fresh batch of app rows on the first scroll,
  several cold-cache icon reads landed in the same frame and dropped it. A new
  shared `AppIconCache` (a `@MainActor` cache modeled on `ClipboardThumbnail`)
  now offloads the disk read to a detached task and memoizes icons by path; the
  non-Sendable `NSImage` crosses back to the main actor via a small
  `@unchecked Sendable` box. Rows seed synchronously from the cache on a warm
  path (no flash) and resolve off-main on a miss, and both window controllers
  prewarm every app icon when the palette / picker opens so even the first
  scroll finds icons already resolved. The same path-keyed cache backs both the
  command palette and the Spotlight app picker.

## [2.0.0] - 2026-06-04

### Added

- Command Palette: inline scientific calculator. Typing a math expression
  surfaces a Calculator section at the top of the palette; pressing Return
  copies the result and shows a toast. A hand-written, dependency-free
  recursive-descent evaluator (`Calculator` / `CalcTokenizer` / `CalcEvaluator`
  / `CalcFunctions`) runs per keystroke on the main thread — chosen over
  `NSExpression` because it never raises an uncatchable Objective-C exception
  on malformed input and has no arbitrary-selector injection surface; any
  failure simply returns `nil` and shows no section. Supports `+ - * / ^`
  (right-associative power), unary minus, parentheses, a number-suffix percent
  literal (`1234 * 8%` → `98.72`, `200 + 10%` → `200.1`), the constants `pi`
  and `e`, and scientific functions (`sqrt`, `cbrt`, `ln`, `log`/`log10`,
  `log2`, `exp`, `sin`/`cos`/`tan` and inverses/hyperbolics in radians,
  `floor`/`ceil`/`round`, plus binary `pow`/`min`/`max`). Detection is
  deliberately conservative: bare numbers stay a port search and bare constants
  don't steal command search, so the section only appears for clear expressions
  — prefix with `=` to force calculation of a bare number or constant (`=8080`,
  `=pi`). The displayed result is grouped/locale-aware while the copied text is
  locale-independent (`.` decimal, no grouping); the copy suppresses
  clipboard-history capture like the other internal copy paths, and input
  length / token count / recursion depth are bounded as a safety guard.

## [1.9.1] - 2026-06-03

### Fixed

- Hosts writes failed silently on signed (Developer ID) builds: activating a
  profile reverted its toggle and `/etc/hosts` was never written. The privileged
  helper's caller code-signing requirement hard-coded the wrong team OU
  (`4GH398M5WH`, detected from an Apple Development cert) instead of the Developer
  ID Application team ID (`9VM4RM39R3`), so `SecCodeCheckValidity` rejected the
  legitimately-signed app on every XPC connection and each write rolled back.
  Corrected the requirement to the real team OU, verified with
  `codesign --verify -R` against the signed app.

## [1.9.0] - 2026-06-03

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
