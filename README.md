# AnyDoor

**English** | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ZingerLittleBee/AnyDoor/total?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases)
[![License](https://img.shields.io/github/license/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS_14+-000000?logo=apple&logoColor=white&style=for-the-badge)](https://www.apple.com/macos)
[![Built with Swift](https://img.shields.io/badge/built_with-Swift_6.2-F05138?logo=swift&logoColor=white&style=for-the-badge)](https://www.swift.org)

A macOS menu bar control center driven by global hotkeys. Bind any key
combination to launch and toggle apps, translate text, flip system settings,
or run one-off actions — all without leaving the keyboard.

Press a shortcut to open an app. Press it again to hide it. Use the same
muscle memory to mute audio, lock the screen, sample a color, OCR a screen
region, translate selected or on-screen text, convert and compress images, or
capture and record the screen
— and reach for clipboard history, window layouts, `/etc/hosts` profiles,
external-display brightness, a Hyper Key, and a Spotlight-style command palette
when you need them.

## Demo

<video src="https://github.com/user-attachments/assets/e7fdea91-107b-4d7c-ab91-0cfa1d2912e1" poster="https://github.com/ZingerLittleBee/AnyDoor/raw/main/landing/public/promo-en.jpg" controls></video>

## Features

### App shortcuts

- Global hotkey per app — opens it when not running, activates it when
  backgrounded, hides it when frontmost.
- Inline hotkey recorder with live modifier detection and conflict prompts.
- Drag to reorder shortcuts; toggle visibility per item.

### Built-in system toggles

| Toggle | What it does |
| --- | --- |
| Keep Awake | Holds an `IOPMAssertion` to prevent display/system sleep |
| Mute Audio | Mutes/unmutes the default Core Audio output device |
| Dark Mode | Flips system appearance via AppleScript |
| Hide Desktop Icons | Toggles Finder's desktop icon visibility |
| Show Hidden Files | Toggles `AppleShowAllFiles` in Finder |
| Hide Dock | Toggles Dock auto-hide |
| Auto-hide Menu Bar | Toggles `_HIHideMenuBar` |
| Keyboard Lock | Drops all key events except registered hotkeys (cleaning mode) |

### Built-in actions

- Lock Screen, Display Sleep, System Sleep
- Empty Trash, Flush DNS cache
- Restart Finder / Dock / SystemUIServer + ControlCenter
- OCR a screen region — Vision framework recognizes text and copies it
- Scan QR / barcode — decode a code on screen and copy its payload
- Pick Color — system color sampler captures HEX into the clipboard
- Translate text — open the translation window, translate the current
  selection, or OCR a screen region and translate the recognized text

### Screen capture

- One capture menu, one selection: a hotkey freezes the screen and shows a
  pre-adjustable selection (resize handles, move, re-drag; restored from the
  last selection) with an attached toolbar that switches tool on the fly —
  **region**, **window**, **fullscreen**, **scrolling**, and **recording**.
- Region, window, fullscreen, and timed capture — each also bindable to its
  own hotkey — over a freeze-screen overlay with a crosshair, live dimensions,
  a magnifier loupe, and arrow-key nudge/resize across every connected display.
- **Scrolling capture** for content taller than the screen: an interactive,
  CleanShot X-style session. You scroll the target — up or down — while AnyDoor
  grabs and stitches frames live (overlap-aligned, pixel-exact) behind a growing
  preview with a Done / Cancel bar; the session's own windows never enter the
  shot, and it reuses your last selection.
- **Quick-access overlay** docked in the bottom-left of the screen after a shot:
  a drag-to-share thumbnail plus copy, save, edit, pin on screen, OCR,
  re-capture, and delete (delete also drops it from clipboard history).
- **Annotation editor**: arrow, line, rectangle, ellipse, freehand,
  highlighter, text, blur, pixelate, redaction bar, numbered step counters, and
  non-destructive crop — with per-tool color / stroke / fill, undo/redo, and
  export to copy / save / pin.
- Pin any capture on screen as an always-on-top floating reference.
- Capture settings: save location, filename template, auto-save / auto-copy,
  timer-delay presets (3 / 5 / 10s), and quick-access overlay timeout.

### Screen recording

- Record the full display or a selected region to **MOV**, **MP4**, or animated
  **GIF** via AVFoundation, with a configurable frame rate and optional cursor
  capture, microphone audio, a draggable webcam overlay, and an on-screen
  keystroke display.
- A floating control bar shows elapsed time with pause / resume and stop; the
  finished file is exported in the chosen format and revealed in Finder.
- System (application) audio is not captured — only the microphone.

### Clipboard history

- Background watcher records text, images, and files copied to the
  pasteboard, with a searchable Liquid Glass "wall" to browse and re-paste.
- Recognizes text (OCR), barcodes, and colors inside captured images.
- Per-source exclusions — skip history from password managers and other
  chosen apps; excluded sources travel with backups.

### Translation

- Translate typed text, the current text selection, or text recognized from a
  screen region.
- Run multiple services side by side: Apple on-device translation, Google,
  Bing, DeepL / DeepLX, and OpenAI-compatible providers such as OpenAI,
  DeepSeek, Qwen, Gemini, Kimi, GLM, OpenRouter, Ollama, or a custom endpoint.
- Configure default and fallback target languages; if source and target match,
  AnyDoor automatically uses the second target language.
- Per-service API keys are stored in Keychain. Service definitions, ordering,
  prompt templates, extra request body / headers, and manual-on-expand mode are
  configurable from Settings.
- Apple translation can download required language packs from the Translation
  settings tab on supported macOS versions.
- Translation history groups every provider result from the same run, supports
  favorites, copy, re-translate, retention trimming, and clear-all.
- Text-to-speech can read the source or translated text, with optional
  auto-speak for the first successful result.
- The selected-text fallback preserves the user's full pasteboard contents and
  suppresses AnyDoor's temporary copy/restore writes from clipboard history.

### Image conversion

- Ships as an installable plugin — enable it from Settings → Plugins.
- A dedicated workspace window — bindable to a hotkey, which also echoes the
  current Finder selection into the basket — with a collapsible sidebar (⌘B)
  holding the pending basket and conversion history, an original/result
  comparison canvas, and a bottom control bar.
- Add images by drag & drop, ⌘O, or ⌘V (copied image files or a copied
  bitmap).
- **Format mode** converts to PNG, JPEG, HEIC, AVIF, WebP, TIFF, GIF, BMP,
  PDF, or ICO, with an exact live result preview — the same bytes a run would
  produce — updating as the quality slider moves.
- **Target Size mode** compresses to a byte budget while keeping the source
  format: JPEG / HEIC / AVIF / WebP via a bounded quality search, PNG by
  scaling down, with scaling always available as a fallback (floored at a
  640 px longest edge). WebP output is encoded by the bundled libwebp.
  Already-fitting sources pass through byte-identical; an unreachable target
  shows an explicit banner with a best-effort Save Anyway.
- Convert All asks where to save the outputs and remembers the folder; runs
  are cancellable (⌘.).
- History records every conversion with its format, output file size, and
  time, plus reveal-in-Finder and copy actions.

### Window layout

- Tile the focused window to halves, thirds, two-thirds, quarters, center,
  or maximize — each on its own optional hotkey.
- Move the focused window to the next / previous display.
- A Window Layout submenu in the panel exposes every arrangement.

### External display brightness

- DDC/CI brightness control for external monitors over VCP `0x10`, with an
  on-screen OSD.
- Architecture-aware backend (Apple Silicon vs. Intel) and global
  brightness up / down hotkeys.

### Hosts management

- Ships as an installable plugin — enable it from Settings → Plugins.
- Edit `/etc/hosts` from a built-in editor with multiple named profiles and
  one-click switching.
- Writes go through a privileged XPC helper (an `SMAppService` daemon),
  falling back to an administrator-authorized AppleScript when the helper
  is not installed.

### Hyper Key

- Remap Caps Lock (or another trigger) to a Hyper modifier
  (Control + Option + Command, optionally Shift) via `hidutil`.
- A quick tap can emit its own action (none / Escape / the original key),
  with a watchdog that re-applies the mapping and clears it on shutdown.

### Scheduled shutdown

- Arm a one-shot shutdown after a chosen delay; it survives relaunch and is
  re-validated after the Mac wakes from sleep.
- A cancelable warning panel appears before it fires; execution is graceful
  (System Events) or forced (privileged helper).

### Port Manager

- Submenu listing every listening port on the system.
- Search by port number or process name.
- Flat list and process-grouped tree views.
- Live refresh with retry on scan failure.

### Command Palette

- A Spotlight-style launcher (global hotkey) that searches and runs any
  command, app, built-in, or listening port from one place.
- Inline calculator: type a math expression and the result appears at the top
  — press Return to copy it. Supports arithmetic, parentheses, powers (`^`),
  percentage literals (`1234 * 8%`), the constants `pi` / `e`, and scientific
  functions (`sqrt`, `sin`, `log`, `pow`, …; trig in radians). Bare numbers
  stay a port search; prefix with `=` to force calculation (e.g. `=8080`).
- Inline conversions: type a conversion and the answer appears on top — Return
  copies it. Units (length, mass, temperature, data size, speed) via `3 ft to m`
  / `72 f to c` / `1 gb to mib`; time zones via `3pm tokyo` / `9am london to
  tokyo`; currency via `100 usd to eur` (also `$` / `€` / `£`, colloquial names
  like `rmb` / `yuan` / `euro`, and `=` as a connector), converted against ECB
  rates cached daily from Frankfurter and usable offline. A currency-only footer
  can force-refresh the rate table on demand.
- Inline developer tools: `base64`, `url`, and `md5` / `sha1` / `sha256` encode
  or hash the rest of the query; pasting JSON pretty-prints / minifies it and a
  Unix epoch renders local / UTC / ISO 8601. A Raycast-style scope badge turns a
  keyword into a search-bar pill so the list stays exclusive to that tool.
- Script plugins add their own rows to the palette — searchable second-level
  lists and paginated markdown detail pages included (see Plugins).

### Quicklinks

- User-defined command-palette entries that open a web URL, a file or folder, an
  app deeplink, or a search template with a `{query}` placeholder. The editor's
  Type picker adapts the field hint per kind and offers a native folder / file
  picker so a directory can be chosen without typing a path.
- Search Templates take inline arguments (`gh AnyDoor`); typing a template's
  keyword and pressing Tab collapses it into a badge in the search field so you
  type just the query next, and Backspace on the empty field sheds it.
- Assign a keyword for direct palette invocation or a global hotkey — plain
  links open immediately, Search Templates summon argument mode.
- Pin an Open With app to override the default handler (falls back to the system
  default if that app is gone); icons derive from the pinned app, file / folder
  metadata, the deeplink handler, or a cached web favicon.
- Drag to reorder, toggle visibility, and the whole configuration participates
  in backup / sync. A set of common templates (Google, GitHub, YouTube, Stack
  Overflow, npm, MDN, Google Translate, ChatGPT) is seeded out of the box.

### Plugins

- Optional features ship as installable plugins, managed from **Settings →
  Plugins** — Image Conversion and Hosts management today. Uninstalling removes
  a plugin's panel rows, palette commands, and hotkeys everywhere, but keeps its
  data and preferences, so reinstalling restores them without a relaunch.
  Upgrading users keep what they already used — prior usage installs those
  plugins automatically.
- **Script plugins**: sideload plugins authored in TypeScript and bundled to
  plain JavaScript, executed on the system JavaScriptCore (no bundled JS
  runtime). They contribute rows to the command palette, with searchable
  drill-in lists and paginated markdown detail pages.
- Ready-to-install example plugins (V2EX and Hacker News browsers) are attached
  to each [release](https://github.com/ZingerLittleBee/AnyDoor/releases) as
  `plugin-*.zip` — unzip, then pick the folder in **Settings → Plugins →
  Install Script Plugin**.
- A script plugin can only use the capabilities its manifest declares — network
  fetch, a private key-value store, toasts, clipboard write, a one-shot delay,
  opening http(s) URLs, and translation through your configured services. No
  shell, no filesystem, no clipboard read; a runaway script is killed by a
  30-second watchdog without affecting other plugins.
- For authors: a typed API package, a `create-plugin` scaffold, and worked
  examples live under `tooling/`, and a developer mode loads a plugin directory
  in place with hot reload on every build.

### Menu bar panel

- Click the menu bar icon to open a Liquid Glass panel listing every
  enabled item with its current state and hotkey.
- Hover the App Shortcuts or Port Manager rows to open side popovers.
- Toast feedback for OCR / color picker results.
- In-panel update banner when a new release is available.

### Settings

- **Panel** tab: drag-to-reorder (top-level items and app-shortcut /
  window-layout children alike), per-item visibility, inline hotkey
  recorder, type badges (toggle / action / submenu).
- **Quicklinks** tab: create / edit command-palette entries with a link type
  picker, keyword, Open With override, hotkey, and visibility; drag to reorder.
- **Clipboard** tab: history monitoring, copy-only capture, retention
  window, per-source app exclusions, and clear-all history.
- **Screenshot** tab: save location, filename template, auto-save /
  auto-copy, timer-delay presets, quick-access overlay timeout, and
  recording options.
- **Translation** tab: target languages, auto-speak, service ordering,
  provider/API-key setup, Apple language-pack downloads, and history retention.
- **Plugins** tab: install / uninstall plugins, sideload script plugin
  packages, and manage script-plugin developer mode.
- **General** tab: launch at login, language, menu bar icon style, Hyper
  Key, command palette hotkey, scheduled shutdown, accessibility /
  automation / screen-recording permission status with one-click request,
  configuration backup / restore, and auto-update controls.

### Auto-update

- Sparkle integration with EdDSA-signed appcast.
- Configurable check frequency (daily / weekly / off) and manual check.
- Update banner surfaces new versions inside the menu bar panel.

### Backup & restore

- Export app shortcuts, built-in preferences, clipboard / capture settings,
  translation target languages, auto-speak, service definitions, the installed
  plugin set, and other whitelisted general settings into a versioned snapshot,
  and import it on another Mac.
- Clipboard history, translation history, API keys, and machine-specific keys
  are excluded; app paths are re-resolved from bundle IDs on import, and
  changes apply without a relaunch.

### Security & permissions

- Runs as an `.accessory` app (no Dock icon).
- Accessibility and Automation permission flows built into Settings with
  live status indicators.
- CGEvent tap at HID level with a watchdog that restarts itself if macOS
  disables it for exceeding the callback budget.

## Requirements

- macOS 14 (Sonoma) or later
- Liquid Glass effects light up on macOS 26 (Tahoe); macOS 14–25 fall back
  to a standard material surface.
- Swift 6.2
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Install

```bash
git clone https://github.com/ZingerLittleBee/AnyDoor.git
cd AnyDoor
make install
```

This builds the release binary and installs `/Applications/AnyDoor.app` with
the app bundle metadata and icon.

For a binary-only build, use:

```bash
make swift-release
```

The binary will be at `.build/release/AnyDoor`.

## Usage

1. Run AnyDoor — an icon appears in the menu bar
2. Click the icon → **Settings** to open the settings window
3. Click **+** to add a binding:
   - Click the shortcut field and press your desired key combination
   - Click **Select...** to choose the target app
   - Click **Save**
4. Press the shortcut to toggle the app (open/hide/activate)

## Development

```bash
# Hot-reload dev mode (requires watchexec)
make

# Build
make build

# Release build only
make swift-release
```

## Release Packaging

Releases are signed with Developer ID, notarized with Apple, packaged as a DMG
and Sparkle zip, then published to GitHub Releases with an updated appcast.
The release Make targets automatically load `.env` through `bash`, so the same
commands work from fish, zsh, bash, or sh.

### Packaging commands

```bash
# Build the release binary only.
make swift-release

# Build and install /Applications/AnyDoor.app for local use.
make install

# Remove /Applications/AnyDoor.app.
make uninstall

# Download the pinned Sparkle command line tools.
make sparkle-tools

# Create or update the notarytool keychain profile from .env.
make notary-profile

# Verify the Developer ID signing identity in the login keychain.
security find-identity -v -p codesigning

# Verify the notarytool keychain profile from .env.
make notary-check

# Validate the full release pipeline without committing, tagging, pushing,
# or creating a GitHub release.
make release-dryrun 1.0.1

# Omit the version to auto-increment the patch version from Info.plist.
make release-dryrun

# Publish a real signed and notarized release.
make release 1.1.0
```

### One-time machine setup

1. Copy `.env.example` to `.env` and fill the local release values.

   Keep `.env` local only. It is ignored by git.
   Fill `APPLE_ID`, `APPLE_TEAM_ID`, `NOTARY_PROFILE`,
   `SIGNING_IDENTITY`, and `REPO_URL`. Leave
   `APPLE_APP_SPECIFIC_PASSWORD` empty after the notary profile has been
   saved to Keychain.

2. Confirm the Developer ID signing identity exists in the login keychain:

   ```bash
   security find-identity -v -p codesigning
   ```

   The expected identity is:

   ```bash
   Developer ID Application: Bee Zinger (9VM4RM39R3)
   ```

3. Create the notarytool keychain profile if it does not already exist:

   ```bash
   make notary-profile
   ```

   Enter the Apple app-specific password at the secure prompt. After this
   succeeds, the password is stored in Keychain under `NOTARY_PROFILE`; it is
   not needed for future release builds and should not remain in `.env`.

4. Verify the notary profile:

   ```bash
   make notary-check
   ```

5. Install the local release tools:

   ```bash
   brew install create-dmg
   make sparkle-tools
   ```

6. Confirm GitHub CLI authentication:

   ```bash
   gh auth status -h github.com
   ```

### Dry run

Run this before every real release. It signs, notarizes, packages, signs the
Sparkle update, and generates `appcast.xml`, but stops before committing,
tagging, pushing, or creating a GitHub release.

This uses the same preflight checks as a real release: run it from a clean
`main` branch that is in sync with `origin/main`.

```bash
make release-dryrun 1.0.1
```

If no version is passed, the script increments the patch version from the
current `CFBundleShortVersionString`. The current value must already be strict
`MAJOR.MINOR.PATCH`.

Expected outputs include:

- `dist/AnyDoor.app`
- `dist/AnyDoor-1.0.1.zip`
- `dist/AnyDoor-1.0.1.dmg`
- `appcast.xml`

### Real release

Real releases must run from a clean `main` branch that is in sync with
`origin/main`. The `CHANGELOG.md` `## [Unreleased]` section must be non-empty.

```bash
git checkout main
git pull --ff-only origin main

make release 1.1.0
```

Pass the version explicitly for real releases.

The release script bumps `Info.plist`, moves the changelog entry, builds,
codesigns, notarizes, packages the DMG and zip, regenerates the Sparkle appcast,
commits, tags, pushes, creates a draft GitHub release, uploads assets, and then
publishes it.

## How It Works

- **CGEvent tap** at HID level (`.cghidEventTap`) intercepts keyboard events before any app
- **SwiftData** persists key bindings across launches
- **AppKit menu bar** — an `NSStatusItem` plus a floating `NSPanel` (managed by
  `MenuBarController`), not SwiftUI's `MenuBarExtra`
- **Privileged XPC helper** writes `/etc/hosts` after verifying the caller's code signature
- **Translation coordinator** fans out requests to enabled providers, records
  per-run history, and guards stale async results from superseded runs
- App runs as an accessory (no Dock icon)

## Tech Stack

- SwiftUI views hosted in AppKit windows + AppKit menu bar (`NSStatusItem` +
  `NSPanel`)
- SwiftData
- JavaScriptCore for the script plugin runtime
- CGEvent tap (`.cghidEventTap`)
- Privileged XPC helper for `/etc/hosts`
- Vision OCR, Natural Language detection, AVFoundation speech, and Apple's
  Translation framework when available
- Swift Package Manager

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for the
development setup, code conventions, and pull-request process. For larger
changes, please open an issue first to discuss the idea.

## Acknowledgements

Bundled third-party code; full license texts in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

- [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT) — its `IntelDDC` is vendored for DDC/CI brightness control of external displays on Intel Macs (itself adapted from [@reitermarkus](https://github.com/reitermarkus)'s work).
- [Sparkle](https://sparkle-project.org/) (MIT) — application auto-update.
- [AskForPermission](https://github.com/riko2chen/AskForPermission) (MIT) — macOS accessibility permission helper.
- [libwebp](https://chromium.googlesource.com/webm/libwebp) (BSD-3-Clause) — WebP encoding for Image Conversion (via SDWebImage/libwebp-Xcode); macOS decodes WebP natively but cannot encode it.

## License

MIT
