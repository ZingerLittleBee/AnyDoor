# AnyDoor

**English** | [简体中文](README.zh-CN.md)

[![Release](https://img.shields.io/github/v/release/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/ZingerLittleBee/AnyDoor/total?style=for-the-badge&cacheSeconds=3600)](https://github.com/ZingerLittleBee/AnyDoor/releases)
[![License](https://img.shields.io/github/license/ZingerLittleBee/AnyDoor?style=for-the-badge&cacheSeconds=3600)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS_14+-000000?logo=apple&logoColor=white&style=for-the-badge)](https://www.apple.com/macos)
[![Built with Swift](https://img.shields.io/badge/built_with-Swift_6.2-F05138?logo=swift&logoColor=white&style=for-the-badge)](https://www.swift.org)

A macOS menu bar control center driven by global hotkeys. Bind any key
combination to launch and toggle apps, flip system settings, or run one-off
actions — all without leaving the keyboard.

Press a shortcut to open an app. Press it again to hide it. Use the same
muscle memory to mute audio, lock the screen, sample a color, or OCR a screen
region — and reach for clipboard history, window layouts, `/etc/hosts`
profiles, external-display brightness, a Hyper Key, and a Spotlight-style
command palette when you need them.

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
- Screenshot to clipboard (interactive region capture)
- OCR a screen region — Vision framework recognizes text and copies it
- Scan QR / barcode — decode a code on screen and copy its payload
- Pick Color — system color sampler captures HEX into the clipboard

### Clipboard history

- Background watcher records text, images, and files copied to the
  pasteboard, with a searchable Liquid Glass "wall" to browse and re-paste.
- Recognizes text (OCR), barcodes, and colors inside captured images.
- Per-source exclusions — skip history from password managers and other
  chosen apps; excluded sources travel with backups.

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

### Menu bar panel

- Click the menu bar icon to open a Liquid Glass panel listing every
  enabled item with its current state and hotkey.
- Hover the App Shortcuts or Port Manager rows to open side popovers.
- Toast feedback for OCR / color picker results.
- In-panel update banner when a new release is available.

### Settings

- **Panel** tab: drag-to-reorder, per-item visibility, inline hotkey
  recorder, type badges (toggle / action / submenu).
- **General** tab: launch at login, menu bar icon style, accessibility
  and automation permission status with one-click request, auto-update
  controls, and configuration backup / restore.

### Auto-update

- Sparkle integration with EdDSA-signed appcast.
- Configurable check frequency (daily / weekly / off) and manual check.
- Update banner surfaces new versions inside the menu bar panel.

### Backup & restore

- Export app shortcuts, built-in preferences, and whitelisted general
  settings into a versioned snapshot, and import it on another Mac.
- Clipboard history and machine-specific keys are excluded; app paths are
  re-resolved from bundle IDs on import, and changes apply without a relaunch.

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
- App runs as an accessory (no Dock icon)

## Tech Stack

- SwiftUI `Settings` scene + AppKit menu bar (`NSStatusItem` + `NSPanel`)
- SwiftData
- CGEvent tap (`.cghidEventTap`)
- Privileged XPC helper for `/etc/hosts`
- Swift Package Manager

## Acknowledgements

Bundled third-party code; full license texts in [THIRD-PARTY-LICENSES.md](THIRD-PARTY-LICENSES.md).

- [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT) — its `IntelDDC` is vendored for DDC/CI brightness control of external displays on Intel Macs (itself adapted from [@reitermarkus](https://github.com/reitermarkus)'s work).
- [Sparkle](https://sparkle-project.org/) (MIT) — application auto-update.
- [AskForPermission](https://github.com/riko2chen/AskForPermission) (MIT) — macOS accessibility permission helper.

## License

MIT
