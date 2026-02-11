# AnyDoor

macOS menu bar app for toggling apps with global hotkeys.

Press a shortcut to open an app. Press it again to hide it. That's it.

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

# Release build
make release
```

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
