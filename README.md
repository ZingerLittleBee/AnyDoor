# AnyDoor

[中文](README.zh-CN.md)

A macOS menu bar control center driven by global hotkeys. Bind any key
combination to launch and toggle apps, flip system settings, or run one-off
actions — all without leaving the keyboard.

Press a shortcut to open an app. Press it again to hide it. Use the same
muscle memory to mute audio, lock the screen, sample a color, OCR a screen
region, and more.

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
- Pick Color — system color sampler captures HEX into the clipboard

### Port Manager

- Submenu listing every listening port on the system.
- Search by port number or process name.
- Flat list and process-grouped tree views.
- Live refresh with retry on scan failure.

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
  controls.

### Auto-update

- Sparkle integration with EdDSA-signed appcast.
- Configurable check frequency (daily / weekly / off) and manual check.
- Update banner surfaces new versions inside the menu bar panel.

### Security & permissions

- Runs as an `.accessory` app (no Dock icon).
- Accessibility and Automation permission flows built into Settings with
  live status indicators.
- CGEvent tap at HID level with a watchdog that restarts itself if macOS
  disables it for exceeding the callback budget.

## Requirements

- macOS 26+ (Tahoe)
- Swift 6.2
- Accessibility permission (System Settings → Privacy & Security → Accessibility)

## Install

```bash
git clone https://github.com/ZingerLittleBee/AnyDoor.git
cd AnyDoor
swift build -c release
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

### Packaging commands

```bash
# Load local release variables for the current shell.
set -a
source .env
set +a

# Build the release binary only.
make swift-release

# Build and install /Applications/AnyDoor.app for local use.
make install

# Remove /Applications/AnyDoor.app.
make uninstall

# Download the pinned Sparkle command line tools.
make sparkle-tools

# Verify the Developer ID signing identity in the login keychain.
security find-identity -v -p codesigning

# Verify the notarytool keychain profile.
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"

# Validate the full release pipeline without committing, tagging, pushing,
# or creating a GitHub release.
make release-dryrun VERSION=1.0.1

# Publish a real signed and notarized release.
make release VERSION=1.1.0
```

### One-time machine setup

1. Copy `.env.example` to `.env` and fill the local release values.

   Keep `.env` local only. It is ignored by git.

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
   set -a
   source .env
   set +a

   xcrun notarytool store-credentials "$NOTARY_PROFILE" \
     --apple-id "$APPLE_ID" \
     --team-id "$APPLE_TEAM_ID"
   ```

   Enter the Apple app-specific password at the secure prompt. After this
   succeeds, the password is stored in Keychain under `NOTARY_PROFILE`; it is
   not needed for future release builds and should not remain in `.env`.

4. Verify the notary profile:

   ```bash
   xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
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

```bash
set -a
source .env
set +a

make release-dryrun VERSION=1.0.1
```

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

set -a
source .env
set +a

make release VERSION=1.1.0
```

The release script bumps `Info.plist`, moves the changelog entry, builds,
codesigns, notarizes, packages the DMG and zip, regenerates the Sparkle appcast,
commits, tags, pushes, creates a draft GitHub release, uploads assets, and then
publishes it.

## How It Works

- **CGEvent tap** at HID level (`.cghidEventTap`) intercepts keyboard events before any app
- **SwiftData** persists key bindings across launches
- **MenuBarExtra** with `.window` style provides the menu bar popup
- App runs as an accessory (no Dock icon)

## Tech Stack

- SwiftUI (MenuBarExtra + Settings)
- SwiftData
- CGEvent tap
- Swift Package Manager

## License

MIT
