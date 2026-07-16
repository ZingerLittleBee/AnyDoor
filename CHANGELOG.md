# Changelog

All notable changes to AnyDoor are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and uses semantic
versioning.

## [Unreleased]

### Added

- Plugins: new 「插件」 tab in Settings. Image Conversion is the first Native
  Plugin — install or uninstall it with one click, no relaunch. While
  uninstalled it disappears everywhere (panel row, command palette, recorded
  hotkeys, the workspace window, and the clipboard-history convert action);
  uninstalling cancels an in-progress conversion first. Conversion history,
  preferences, and hotkeys are kept, so reinstalling restores your exact
  previous setup.
- Command Palette now opens where you last left it, including after restarting
  AnyDoor. If that monitor is no longer connected, the palette returns to its
  default position.

## [3.7.0] - 2026-07-12

### Added

- Image Conversion: added a Target Size mode with bounded, cancellable
  compression and explicit Best-Effort saves, plus a workspace window with a
  collapsible sidebar (⌘B) holding the basket/history switch, an
  original/result comparison canvas, and an attached bottom control bar —
  all under standard window chrome that blends the title bar into the canvas.
- Image Conversion: Target Size now keeps the source format instead of
  converting (the target-format picker is gone), and supports five formats —
  JPEG, HEIC, AVIF, and WebP on a quality search, and PNG by scaling down
  (its only lever). Scaling down is always available as a fallback (no
  opt-in toggle), floored at a 640 px longest edge. WebP output is encoded
  by the bundled libwebp (BSD-3-Clause), since macOS can decode but not
  encode WebP. Formats without a compression strategy (GIF/TIFF/BMP/ICO)
  are reported as unsupported per item.
- Image Conversion: Format mode now shows an exact result preview for the
  selected item — the same bytes a run would produce for the chosen format
  and quality — updating live as the quality slider moves.
- Image Conversion: Convert All first asks where to save the outputs and
  remembers the last chosen folder; Save Anyway commits to the same place.
  The conversion window is a normal window instead of an always-on-top
  panel.
- Image Conversion: history entries now show the output file size next to
  the format; entries recorded before this version fall back to the output
  file's current size on disk.

### Changed

- The Settings window now uses the same window type as the Image Conversion
  workspace — standard chrome with a transparent title bar, the sidebar
  running full height around the traffic lights at their default position —
  and Esc closes it. It stays fixed-size with a non-collapsible sidebar.
- Clipboard wall: search is focused explicitly instead of by typing — ⌘F
  toggles the field (↓ also returns to the cards, keeping the query), and
  the shortcut is shown in the hints footer.

### Removed

- The "New Quicklink" built-in (added in 3.6.0) is gone from the panel and
  command palette; quicklinks are created in Settings → Quicklinks, which the
  built-in merely opened.

### Fixed

- Image Conversion: hardened basket preflight, cancellation, frozen run state,
  atomic output commits, candidate metadata validation, preview artifact
  cleanup, and transactional history writes with visible persistence warnings.
- Importing a settings backup now applies the Image Conversion preferences to
  an already-open conversion window. The window previously kept its cached
  values, so toggling any control wrote the stale state back over the
  just-imported settings (this affected the format/quality keys synced since
  3.5.0 as well as the new Target Size keys).
- Target Size no longer inflates a source that already fits the target: a
  metadata-clean source is emitted byte-identical (the only pass-through
  possible for WebP/AVIF, which Image I/O cannot rewrite), and the lossless
  rewrite now preserves EXIF orientation instead of being rejected by the
  audit and falling back to a larger re-encode.
- HEIC Target Size conversion no longer fails the metadata audit on macOS 26,
  which surfaces HEIF structural tile tags (`tiff:TileLength`/`TileWidth`)
  on every HEIC, including freshly encoded ones.
- Screen-share and recording tools that capture AnyDoor specifically (an
  app-filtered ScreenCaptureKit stream) could not start their stream: an
  invisible helper window sat outside every display, which makes
  WindowServer mark the app uncapturable. The window now stays on screen.
- Clipboard wall: fixed search-focus desyncs — clicking into the field could
  leave keys acting on the cards (⌫ deleted the selected card), the wall
  could open with the field pre-focused, and reopening the wall silently
  broke keyboard search focus.

## [3.6.0] - 2026-07-10

### Added

- Quicklinks: a new Settings tab manages user-defined command-palette entries
  that open plain web URLs, deeplinks, files, or folders, with visibility
  toggles and drag reorder. Search Templates appear in palette results and
  support exact keyword/full-name inline arguments such as `gh AnyDoor`;
  alternatively, typing a template's keyword and pressing Tab collapses it into
  a badge (Raycast-style) so you type just the query next, and Backspace on the
  empty field sheds the badge. Quicklinks can also record global hotkeys, with
  plain links opening directly and Search Templates summoning argument mode.
  Entries can pin an Open With app override, falling back to the system default
  if that app disappears, and their icons are derived from the pinned app,
  file/folder metadata, deeplink handlers, or cached web favicons. The full
  Quicklinks configuration participates in backup/sync, and a new "New
  Quicklink" built-in opens Settings directly to the Quicklinks tab. A set of
  common search templates (Google, GitHub, YouTube, Stack Overflow, npm, MDN,
  Google Translate, and ChatGPT) is seeded out of the box as ready-to-use
  entries you can edit or delete like any other.
- Onboarding: a new App Shortcuts step demos the product's core interaction —
  a bound hotkey presses down on a mock desktop and the target app's window
  springs to the front over the dimmed previous window, a second press hides
  it; chips cycle through example apps.
- Onboarding: two new steps demo Translation and Image Conversion with
  animated mocks of the real UI — the translation panel auto-types a sentence,
  detects the language, and streams results from two services in parallel; the
  conversion window replays a drag-in, one-click convert, and the output
  landing in history. Both honor Reduce Motion.

## [3.5.0] - 2026-07-06

### Added

- Image Conversion: a new built-in action opens a floating conversion window
  where images can be batch-converted through ImageIO to PNG, JPEG, HEIC, AVIF,
  TIFF, GIF, BMP, PDF, or ICO when the system encoder supports the target
  format. Images enter the basket by dragging files in, pressing ⌘V (copied
  files or a copied bitmap), summoning the window with images selected in
  Finder (the selection is echoed in; the hotkey is a strict open/close
  toggle), or right-clicking an image/screenshot/file card on the clipboard
  wall. File sources convert next to the original (never overwriting — name
  collisions get a Finder-style counter); clipboard bitmaps convert into
  Downloads with a timestamped name; outputs land on the clipboard as files,
  ready to paste.
- Image Conversion: a quality slider (1–100%, default 85%) applies to lossy
  targets (JPEG/HEIC/AVIF); the last-used format and quality persist and are
  included in config backup/sync.
- Image Conversion: the window keeps the last 50 conversion records with
  thumbnails, Reveal in Finder, copy-as-file, and a clear-all action.
- Screenshot "Save As" can now save in any supported image format (PNG, JPEG,
  HEIC, AVIF, TIFF, GIF, BMP, PDF, ICO) — the chosen filename extension picks
  the format and lossy saves honor the Image Conversion quality setting. The
  capture pipeline itself still records PNG.

## [3.4.1] - 2026-07-04

### Changed

- Clipboard wall cards grew from 190×190 to 230×230 (panel height 285→325),
  with larger preview and match-snippet text, improving legibility of longer
  text/OCR/QR previews.

### Fixed

- Release builds appeared washed-out on macOS 26 (Tahoe). The universal-binary
  build uses the `swiftbuild` backend, which records the deployment-target
  version (14.0) in the binary's `LC_BUILD_VERSION` `sdk` field instead of the
  real SDK version. macOS 26 gates the modern window appearance on the linked
  SDK version (>= 26), so the released app fell back to the legacy appearance
  while `swift run` (native backend, real SDK) looked correct. The release
  script now forces `platform_version` to the real SDK version, keeping `minos`
  at 14.0 so the app still runs on macOS 14+.
- The Settings window opened by itself on every launch of the released app —
  most visibly after a reboot/login auto-launch. Same root cause as the
  washed-out appearance above: with a 14.0 `sdk` stamp, macOS 26's SwiftUI
  applies the legacy behavior where an app whose only scene is `Settings`
  presents that window at launch, regardless of the launch mechanism (login
  item, `open -a`, direct exec). Verified by A/B-stamping the same binary with
  `vtool`: `sdk 14.0` opens the window, the real SDK keeps it closed. The
  state-restoration and reopen-suppression defenses in `AppDelegate` were never
  the trigger. Fixed by the `platform_version` override above.
- Release tooling now asserts the minimum-macOS declaration stays in sync across
  `scripts/release.sh` (`MIN_MACOS`), `Package.swift` (`.macOS`), and
  `Info.plist` (`LSMinimumSystemVersion`). The `platform_version` override force-
  stamps `minos`, so without this guard a future platform bump would silently
  ship a binary claiming support for an older macOS than it was built for.
- Clipboard wall cards intermittently showed a blank source-app icon after fast
  scrolling. The icon was resolved through an async `.task` that could be torn
  down by the wall's frequent view-body re-evaluations before the detached
  resolve landed; the source icon is a single cheap Launch Services lookup, so
  it's now resolved synchronously on the main actor instead.
- The clipboard wall's source-filter trigger showed a blue keyboard focus ring
  when the wall opened, unlike the tab row beside it. It's no longer part of
  the focus chain (mouse clicks still open the menu).
- Hyper Key: retrying the trigger mapping right after a failed `hidutil` GET
  could leave a stale signature in the persisted `hyperKey.ownedSignatures`,
  since only the SET-reached failure path rolled it back. A failed GET (which
  never mutates `hidutil`) now also rolls the persisted ownership back to its
  prior state.
- Hosts: composing or applying against `/etc/hosts` fell back to an empty
  string when the file couldn't be read, risking a write that wiped the
  system's own entries. A failed read now aborts the apply with a surfaced
  error instead.
- Hosts: deleting an active profile removed its SwiftData row before
  confirming the block-removal write to `/etc/hosts` succeeded, so a failed
  write could orphan the block outside any tracked profile. The row is now
  deleted only after the deactivation is applied and verified — including
  against a coalesced `scheduleApply()` result, which can otherwise report a
  batch-mate's success (or a rolled-back no-op retry) instead of this
  profile's own write.
- Clipboard: deleting a history item removed its on-disk payload file
  (PNG/copied files) before the row deletion was saved, so a failed save
  could leave a surviving row pointing at deleted files — and the failed-save
  path never rolled back the pending deletion, letting a later unrelated save
  silently flush it and drop the row anyway. The payload is now captured
  before, and removed only after, the row deletion is confirmed saved; a
  failed save rolls back the pending deletion and refreshes from the
  persisted state.

## [3.4.0] - 2026-06-29

### Added

- Settings › 面板 edit mode. A top-right 编辑 / 完成 toggle (mirroring SwiftUI's
  iOS-only `EditButton` convention) flips the list into edit mode: each row's
  drag handle and visibility checkbox slide in from the leading edge while the
  content reflows, and the usage tip appears at the bottom. Out of edit mode the
  list reads as a clean reference view — no checkbox or handle clutter — with
  hidden items still conveyed by dimming. Changes apply live; there is no
  separate save step. The visibility checkbox is now a lightweight pure-SwiftUI
  control, so it carries no AppKit focus ring.
- The 屏幕亮度 row is collapsible, like App Shortcuts and Window Layout: its
  brightness-up / brightness-down hotkey rows hide when the row is collapsed.

### Changed

- Settings tab switching no longer hitches. Several tabs did blocking
  main-thread work that the `TabView` re-paid on every switch:
  - The General tab read launch-at-login (`SMAppService.status`) and the
    Accessibility / Automation / Screen-Recording permission state in `@State`
    initializers — which the TabView re-evaluates each time it rebuilds a tab's
    view — so every switch paid for them. They now default to cheap placeholders
    and load off the main thread.
  - The Clipboard tab scanned installed apps (an `/Applications` walk plus
    bundle reads) on the main actor in its `.task`; it now runs detached.
  - The 面板 list renders its reorder handles, visibility checkboxes, and
    per-row frame probes only while in edit mode, so the resting list is far
    lighter to lay out. Together these cut the 面板 tab's switch cost from
    ~140 ms to ~40 ms.

## [3.3.0] - 2026-06-26

### Added

- Translation: a floating multi-service panel with auto source detection,
  language swap, streaming results, copy, TTS, pinning, and access from a builtin,
  global hotkey, or the command palette.
- Translation providers and settings: Apple on-device, Google, Bing, DeepL /
  DeepLX, and OpenAI-compatible endpoints with provider presets, Keychain-stored
  API keys, manual-on-expand LLM services, Apple language-pack downloads, and
  backup sync for non-secret settings.
- Translation entry points and history: translate selected text, translate OCR
  from a screenshot region, browse per-run history and favorites, re-translate,
  and trim history with a retention cap.

### Changed

- Failure toasts now stay on screen for 5 seconds instead of the ~1 second used
  for success and color toasts, so an error message can actually be read.
- The blue keyboard focus ring is removed across all of the app's windows for a
  cleaner look.
- Build tooling: the string-catalog compiler plugin now uses SwiftPM's current
  URL APIs for generated input and output paths.

## [3.2.0] - 2026-06-21

### Added

- Clipboard wall: ⌘K opens the source-app filter from the keyboard (in both the
  search-input and card-navigation modes), so the dropdown no longer has to be
  clicked. A "⌘K 筛选来源" hint is added to the wall footer.
- Clipboard wall: ⌘← / ⌘→ jump the card selection to the first / last entry
  (card-navigation mode only — in the search field they still move the text
  caret). The jump scrolls to the target instantly instead of animating, so a
  long history doesn't run a multi-frame scroll animation sweeping across the
  cards. A "⌘←→ 首/尾" hint is added to the footer.

### Changed

- Clipboard wall: the source-app filter now shows real application icons. The
  dropdown was switched from a SwiftUI `Menu` (which doesn't reliably render
  custom `Image(nsImage:)` items on macOS) to a native `NSMenu` popped from a
  view anchor: each source row shows that app's icon via `NSMenuItem.image`, the
  active source keeps the native checkmark, the menu opens upward from the
  trigger at the bottom of the wall, and it auto-scrolls when there are more
  sources than fit. The trigger button itself now shows the selected source's
  icon instead of a generic glyph.
- Clipboard wall: the Launchpad-style tab edit / reorder mode is now armed by
  holding ⌥ instead of ⌘ (the footer hint shows ⌥).
- Clipboard wall performance with large histories. The source-app grouping is
  now computed once per render instead of 4–5 times (it feeds the menu, the
  trigger title, the disable check, and two `onChange` dependencies); the
  list-sync `onChange` trigger hashes the displayed items instead of allocating a
  fresh `[UUID]` on every body evaluation; and match snippets are memoized per
  item for the active query, so a wall re-render or a card re-realized while
  scrolling no longer re-folds the item's text on the main thread.

### Fixed

- Clipboard wall: scrolling over the open source-filter menu moved the cards
  underneath it instead of scrolling the menu. Card-navigation scroll now only
  acts on scroll events targeting the wall window itself, letting scrolls over
  the menu (and the floating text panel) reach their own window.

## [3.1.1] - 2026-06-20

### Fixed

- Light-mode polish across the translucent panels. The menu-bar panel, the hover
  popovers, and the command palette are built on semantic colors and materials
  with no light/dark branching, but a few spots were tuned for a dark backdrop and
  looked off on bright light-mode glass:
  - **Panel edges vanished.** The command palette, its destructive-action confirm
    card, and the Spotlight app picker drew their hairline border with a hardcoded
    `Color.white` opacity, which went white-on-white over the bright surface. They
    now use the semantic `separatorColor` hairline (the token already used by the
    toast and clipboard rows), so the edge stays visible in both appearances.
  - **Rows and buttons rendered too bright.** Interactive rows that sit inside a
    panel which already supplies a material — the menu-bar panel rows (on macOS
    earlier than 26), every App Shortcuts / Window Layout / Hosts / Port Manager
    popover row, and the Port Manager's Refresh / view-mode buttons — each stacked
    a second interactive glass/material on top, so they lit up noticeably lighter
    than the surface around them in light mode. Idle rows now stay transparent
    (letting the single panel material show through) and only paint a neutral hover
    tint, matching the port list; the popover rows also gain a hover highlight they
    previously lacked. macOS 26 keeps its per-row interactive Liquid Glass on the
    menu-bar panel.
  - **A bright scrollbar track.** The Port Manager (list and tree views), the
    clipboard-history popover (list and text preview), and the Bluetooth-battery and
    Spotlight app-picker lists honored the system "Show scroll bars: Always"
    preference, which painted a persistent white scroller track against the
    translucent surface. They now force overlay (floating, auto-hiding) scrollers,
    matching the command palette.
  - **Smaller tweaks.** The off-state toggle knob gains a hairline edge and a
    slightly stronger off-track so it reads on the bright panel; the
    scrolling-capture preview well uses an appearance-adaptive recess instead of a
    fixed black wash; the Port Manager warning banner tint is strengthened so it
    stays distinct over light-mode material; and the command-palette confirmation
    scrim is softened a touch so it is less heavy over bright glass.
- The command palette ignored Esc when the search field was empty. Closing the
  panel dropped the search field's focus, and an unbounded focus-recovery loop
  immediately reasserted it on the next runloop tick — which made the field first
  responder again and reordered the just-closed panel back on screen. Esc was the
  only dismiss path where the app stayed frontmost with no other window to take
  focus, so it was the one that visibly "wouldn't close". The recovery now skips
  reasserting focus once the panel is no longer on screen, and is capped after a
  few rapid strikes (matching the Spotlight app picker).

## [3.1.0] - 2026-06-19

### Added

- A capture sound: a successful screenshot now plays the native macOS screenshot
  shutter (`Screen Capture.aif`, falling back to the system `Shutter` / `Grab`
  sounds) at the moment the capture commits. It covers every successful still
  capture — region, window, fullscreen, and scrolling — through the shared output
  path. A "play sound after capture" toggle in Settings › Capture (on by default)
  controls it, and the preference rides settings backup. Screen recording is
  unaffected (it keeps its own start/stop cues).
- Bluetooth device battery: a new menu-bar panel item whose hover popover lists
  every connected Bluetooth accessory macOS reports a battery level for — AirPods
  and true-wireless earbuds (left / right / case), Apple Magic keyboards, mice,
  and trackpads, generic BLE keyboards and mice that expose the standard GATT
  Battery Service, and Logitech HID++ mice (MX Master and similar). Levels are
  read off the main actor via `ShellRunner` from two public, permission-free
  sources — `system_profiler SPBluetoothDataType -json` (rich; gives the earbud
  left/right/case triple and a device type) and `pmset -g accps` (covers the
  HID++ mice that system_profiler silently omits) — merged by a pure, unit-tested
  `BluetoothBatteryParser` that prefers the richer system_profiler readings and
  folds pmset in for the gaps. Each reading is tinted by charge (red ≤ 20 %,
  yellow ≤ 35 %, green otherwise). macOS exposes no battery-change notification,
  so the list polls on demand when the popover opens and caches for 30 s to avoid
  re-spawning the subprocesses; no new entitlement, TCC prompt, or private API is
  involved.

### Changed

- Menu-bar panel rows now show a subtle hover highlight — a neutral rounded
  fill (8 % of the foreground color, so it reads as a slight lighten in dark
  mode and a slight darken in light mode) layered above the material / glass
  row surface, fading in and out on a short ease. It gives the same
  row-tracking affordance as the command palette and native menus. Only the
  top-level panel rows are highlighted, and hover is detected through the
  AppKit-backed tracking path rather than SwiftUI's `.onHover`.
- Menu-bar hover popovers now align their top edge with the hovered row (a
  drop-down submenu feel) instead of centering vertically on it, shifting up
  only when a tall popover would otherwise run off the bottom of the screen.
  Placement is computed by a pure, unit-tested `HoverPopover.anchorOrigin`.

### Fixed

- Menu-bar hover popovers — App Shortcuts, Port Manager, brightness, Hosts,
  Bluetooth battery, and the clipboard-history side popovers — were janky to
  switch between (worst on rows that open a popover), sometimes failed to
  appear, and could be left on screen as a stray window. Several root causes in
  the shared hover pipeline:
  - Every show and every row-to-row crossing built a throwaway `NSHostingView`
    solely to measure the content's fitting size, and re-mounted synchronously
    on the AppKit mouse-event tick. The popover now reuses a single measuring
    host (one layout pass, no per-show allocation) and coalesces re-mounts a
    frame later off the event tick, so a fast sweep across rows rebuilds once
    instead of once per row crossed.
  - The 400 ms hover-intent delay restarted on every crossing, so a continuous
    sweep never reached it and the popover only appeared once the cursor
    settled; and the hover tracking area was torn down and re-added on every
    layout pass, which drops the mouse-enter edge when it is rebuilt under an
    already-stationary cursor, silently losing the hover. The delay now keeps
    its first deadline (leading-edge), and the tracking area is rebuilt only
    when missing and reconciled against the live cursor so a dropped edge is
    recovered.
  - When a row's on-screen frame had not been recorded yet, the popover
    anchored to the whole menu-bar panel frame, placing it against the panel
    edge instead of beside the row; it no longer falls back to a panel anchor.
  - A key-focus popover (Port Manager or clipboard history) could be orphaned
    as a zombie window when the panel was dismissed by an outside click;
    dismissal now orders out any stray hover panel.
- The clipboard-history popover for 截图到剪贴板 (screenshot to clipboard) opened
  far from the row — pinned near the bottom of the screen — because the four
  screenshot-producing builtins (screenshot, capture window, capture fullscreen,
  capture timer) all map to the same `screenshot` history kind and shared a
  single anchor entry keyed by kind, so whichever row reported its position last
  clobbered the others. Hover anchors are now keyed per row, so each row anchors
  to itself while still showing the shared screenshot history.

## [3.0.0] - 2026-06-18

### Added

- An interactive first-run onboarding: a six-step window (left progress rail,
  right content) where each step teaches through a hand-drawn, animated SwiftUI
  mock rather than walls of text — the menu-bar panel dropping into place, three
  live permission cards (Accessibility / Screen Recording / Automation) wired to
  the real requests, a Hyper Key keyboard demo whose controls drive the real
  Hyper Key settings, a looping capture Quick Access overlay, an auto-typing
  command palette (`300 usd = rmb`, `:3000`, `hosts`) beside the clipboard wall, and a
  Panel-settings customize demo. Back / Continue / Skip / Done are fixed at the
  bottom (Esc skips, Return continues), Reduce Motion is honored, and every
  destructive action is mock-only. It shows once on a clean install, never
  participates in window state restoration, and can be reopened from
  Settings › General › Getting Started.

## [2.7.0] - 2026-06-17

### Added

- A self-timer button on the capture selection toolbar. It captures the current
  region after a configurable countdown, showing a large countdown in the
  lower-middle of the display and an outline of the region being captured so
  transient UI can be arranged during it; press Esc to cancel.
- A "Show in Finder" action in the post-capture overlay, shown when "auto-save
  after capture" has already written the screenshot to disk.
- Tooltips for the annotation editor's preset color swatches and custom-color
  button.

### Changed

- The selection rectangle's corner handles now use the native macOS diagonal
  resize cursors instead of falling back to the crosshair.
- The post-capture overlay's save action is now "Save As" and always opens a
  save panel to choose a destination; use the new Show in Finder action to
  reveal an auto-saved file instead.

### Fixed

- The self-timer now captures the live screen at the end of the countdown. The
  region timer previously presented the still frozen when the selection was
  made, so anything arranged during the countdown was missed; timed region,
  window, and fullscreen captures now re-grab after the countdown.

## [2.6.0] - 2026-06-16

### Changed

- The post-capture quick-access overlay no longer floats beside the selection;
  it now docks in the bottom-left of the active screen, reworked into a
  drag-to-share thumbnail plus a grid of quick actions (copy / save / edit /
  pin / OCR / re-capture / delete). Placement no longer depends on the captured
  region.
- The annotation editor is reorganized into a CleanShot X-style layout: a single
  top toolbar (undo/redo, grouped drawing tools, and the export actions) with a
  contextual style bar beneath it — color swatches, a custom color picker, stroke
  width, and tool-specific font-size / fill controls — and the image floating on a
  neutral backdrop. The editor window now sizes to the screenshot's aspect ratio
  and comes to the front on open (the capture overlay is a non-activating panel,
  so the editor previously opened behind the captured app).
- The annotation crop tool now applies live: the canvas crops and zooms to fit the
  chosen region as you drag, instead of only dimming a preview and cropping on
  export. The crop commits on mouse-up and is undoable, and annotations drawn
  after a crop stay aligned.

### Fixed

- Annotated images no longer export upside-down. The renderer's coordinate space
  did not match its flipped drawing context, so the composited image — and every
  annotation drawn on it — came out vertically mirrored.
- Closing the annotation editor window no longer crashes. The window over-released
  itself because `isReleasedWhenClosed` was left at its default; it now matches the
  other window controllers in the app.
- Undo / redo in the annotation editor take effect immediately. The toolbar chrome
  did not observe document mutations, so the buttons stayed stale and the canvas
  did not redraw after an undo/redo; the canvas now also handles the standard
  Cmd-Z / Shift-Cmd-Z keys.
- The capture mode bar's buttons are fully clickable. A plain SwiftUI button only
  hit-tests its opaque glyph, leaving the label text and surrounding padding as
  dead zones; the entire padded icon + label area is now the hit target, with a
  hover highlight for affordance.
- Scrolling capture now stitches in both scroll directions. The stitcher only
  detected downward scrolling (content moving up, new rows revealed at the bottom),
  so scrolling up matched no overlap and nothing was appended past the seed frame;
  it now prepends the new top rows when scrolling up.
- Scrolling capture remembers and pre-shows the last selection like regular region
  capture, instead of opening an empty selection every time.

## [2.5.0] - 2026-06-16

### Added

- Screenshot capture suite: region, window, fullscreen, and timed capture with a
  freeze-screen selection overlay (crosshair, live dimensions, magnifier loupe
  with a pixel-coordinate readout, arrow-key nudge/resize, and last-selection
  reuse). The selection overlay spans every connected display. After a capture a
  quick-access overlay appears next to the selection with copy, save, edit, pin,
  text extraction (OCR), re-capture, and delete (delete also removes the entry
  from clipboard history). An All-In-One capture menu provides a single entry
  point alongside per-mode hotkeys, and captures can be pinned on-screen as
  always-on-top floating references.
- Scrolling capture: capture content taller than the screen. Select a viewport
  over a scrollable area, then scroll the target yourself in an interactive
  session (CleanShot X style) with a live preview and Done/Cancel while AnyDoor
  stitches the frames (overlap-aligned, pixel-exact) into one tall image that
  flows through the same save / copy / edit / pin / history output as any
  capture. The session's own preview and outline windows are excluded from the
  shot. Reachable from the All-In-One menu, a dedicated builtin, and a hotkey.
- Screen recording: record the full display or a selected region to MOV, MP4, or
  animated GIF via AVFoundation, with a configurable frame rate, optional cursor
  capture, microphone audio, a draggable webcam overlay, and an on-screen
  keystroke display. A floating control bar shows elapsed time with pause/resume
  and stop; the finished file is exported in the chosen format and revealed in
  Finder. Reachable from the All-In-One menu, a dedicated builtin, and a hotkey
  (the hotkey toggles a fullscreen recording on and off). System (application)
  audio is not captured — `AVCaptureScreenInput` cannot, ScreenCaptureKit is
  avoided to dodge a macOS 26 crash, and a Core Audio tap is deferred; only the
  microphone is recorded.
- Screenshot settings tab: save location, filename template, auto-save /
  auto-copy, timer-delay preset (3 / 5 / 10s), and quick-access overlay timeout.
- Annotation editor (reached from the capture overlay's edit button): arrow,
  line, rectangle, ellipse, freehand, highlighter, text, blur, pixelate,
  redaction bar, numbered step counters, select/move, and non-destructive crop,
  with per-tool color / stroke width / fill / text size, undo/redo, and export to
  copy / save / pin.
- Region screenshot now opens with a pre-shown, mouse-adjustable selection
  (resize handles + move + new-drag), restored from the last selection across
  launches or centered by default.

### Changed

- The capture-menu entry now opens the pre-shown selection directly with an attached
  toolbar (region / window / fullscreen) instead of a separate type-picker bar; the
  standalone floating mode bar was removed.
- The capture toolbar now also offers scrolling and recording, acting on the current
  selection — scrolling stitches the selected viewport and recording captures the
  selected region, instead of each starting its own separate selection.

### Fixed

- Screen capture no longer crashes on macOS 26: a still capture corrupted the
  main thread's Swift-concurrency executor tracking, after which hovering a
  menu-bar row (or any other dynamic main-actor check) faulted. The capture
  engine now uses synchronous CoreGraphics and hover handling avoids the broken
  runtime check.

## [2.4.0] - 2026-06-14

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
  search is untouched. The connector can be `to`, `in`, or `=` (e.g. `100 usd =
  rmb`). Currency also accepts common colloquial names (`rmb`/`yuan`
  → CNY, `euro`, `pound`, `yen`, `dollar`, …) in addition to ISO codes. The
  command palette gains a Raycast-style footer — shown only in a currency context
  (a currency row, or a currency-shaped query with no rates yet) — with the
  selected row's primary action on the left and an "更新汇率" button on the right
  that force-refreshes the rate table on demand.
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

### Changed

- Command palette list now uses overlay scrollbars (auto-hiding and reserving no
  width), matching the Raycast-style chrome, regardless of the system "Show scroll
  bars: Always" preference that SwiftUI would otherwise honor.

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

Initial release.

### Added

- Auto-update via Sparkle 2 with assets published to GitHub Releases.
- "关于与更新" section in General settings.
- Menu bar panel banner when a new version is available.

### Changed

- Lowered the minimum supported macOS version to 14.0 (Sonoma) while keeping
  Liquid Glass effects on macOS 26+ only. OCR now uses the legacy
  VNRecognizeTextRequest path, and Settings falls back to the classic
  TabView/tabItem API.
