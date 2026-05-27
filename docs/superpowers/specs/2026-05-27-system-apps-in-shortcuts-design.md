# System Apps in App Shortcuts — Design

## Problem

The "+" button in Settings → 面板 → App Shortcuts currently opens an `NSOpenPanel`
with `directoryURL = /Applications` and `allowedContentTypes = [.application]`.
Users cannot discover or pick system apps such as Finder (lives at
`/System/Library/CoreServices/Finder.app`) or anything under `/System/Applications`
(System Settings, Calculator, Calendar, etc.) without manually navigating with
⌘⇧G. The data model and runtime (`KeyBinding`, `AppSwitcher`,
`HotkeyService`, `PanelStore`) are already path-agnostic; the only gap is the
picker UX.

## Goal

Let users add any installed app — user-installed, system, or Finder — to App
Shortcuts via a discoverable, searchable picker.

## Non-goals

- No new data fields on `KeyBinding`.
- No special toggle semantics for individual apps (Finder uses the same
  `AppSwitcher.toggle` path as third-party apps).
- No support for picking arbitrary executables, scripts, or login items.
- No background re-scanning; the catalog is built lazily per picker open.

## Approach

Replace the `NSOpenPanel` call in `PanelSettingsView.addApp()` with a
SwiftUI sheet that lists installed apps and supports text search. The sheet
returns a selected `InstalledApp` value; the existing
`PanelStore.shared.addAppShortcut(bundleID:name:path:)` write path is unchanged.

## Components

### 1. `InstalledAppsScanner` (new service)

`Sources/AnyDoor/Services/InstalledAppsScanner.swift`

A `@MainActor` enum with one entry point:

```swift
static func scan() -> [InstalledApp]
```

Scans these roots (existing ones only):

- `/Applications`
- `/Applications/Utilities`
- `/System/Applications`
- `/System/Applications/Utilities`
- `~/Applications`

Plus a hardcoded probe for Finder at
`/System/Library/CoreServices/Finder.app` (added only if it exists; macOS 14+
ships it there).

For each `.app` bundle:

- Read `Bundle(url:)`. Skip if `bundleIdentifier` is nil.
- Skip Sparkle helper apps (`*.app` nested inside other apps' `Contents/`).
  Implemented by limiting traversal to direct children of each root.
- Resolve display name from `CFBundleDisplayName`, then `CFBundleName`,
  then file basename.

Deduplicate by `bundleIdentifier` (keep first encountered). Sort by display
name, case-insensitive.

`InstalledApp` is a `Sendable` value type:

```swift
struct InstalledApp: Identifiable, Hashable, Sendable {
    let bundleID: String
    let displayName: String
    let path: String
    var id: String { bundleID }
}
```

No caching across picker opens — the scan is fast (~10ms on a typical Mac)
and a fresh scan handles apps installed since launch.

### 2. `AppPickerSheet` (new view)

`Sources/AnyDoor/Views/AppPickerSheet.swift`

A modal sheet presented from `PanelSettingsView`. Contents:

- Title row with localized "Choose Application" + close button.
- `TextField` search box (focused on appear, placeholder localized).
- Scrolling `List` of filtered `InstalledApp` rows: icon (18pt) + display
  name + secondary path subtitle. Apps already present in any existing
  `KeyBinding` (by `bundleIdentifier`) are excluded from the list.
- Rows whose `path` begins with `/System/` show a small localized "系统" /
  "System" tag next to the display name to make their origin obvious.
- A single click / tap on a row calls `onSelect(InstalledApp)` and dismisses
  the sheet.
- Bottom bar: Cancel button (Esc).

The view is dumb: it receives `[InstalledApp]`, an `excludedBundleIDs: Set<String>`,
and an `onSelect` callback. No store dependency.

### 3. `PanelSettingsView.addApp()` rewrite

Replace the `NSOpenPanel` block with `@State` toggling a `.sheet` modifier on
the parent `VStack`. On sheet open, call `InstalledAppsScanner.scan()` and
build `excludedBundleIDs` from `PanelStore.shared.appShortcutChildren`'s
underlying KeyBindings. On selection:

```swift
PanelStore.shared.addAppShortcut(
    appBundleID: app.bundleID,
    appName: app.displayName,
    appPath: app.path
)
```

### 4. Localization

Add three new keys to `Sources/AnyDoor/Resources/Localizable.xcstrings` and
the matching cases in `Utilities/L10n.swift`:

- `settings.appPicker.searchPlaceholder` — en: "Search apps", zh-Hans: "搜索应用"
- `settings.appPicker.empty` — en: "No matching apps", zh-Hans: "没有匹配的应用"
- `settings.appPicker.subtitleSystem` — en: "System", zh-Hans: "系统"
  (small tag on rows whose path starts with `/System/`)

The existing `settings.appPicker.title` ("Choose Application" / "选择应用程序")
is reused as the sheet header.

## Data flow

```
[+] button
  ↓
PanelSettingsView (@State showingPicker = true)
  ↓
AppPickerSheet (.sheet)
  ↓ InstalledAppsScanner.scan() once on appear
  ↓ user picks row
  ↓ onSelect(InstalledApp)
  ↓
PanelStore.shared.addAppShortcut(bundleID, name, path)
  ↓ (existing path: inserts KeyBinding, saves, rebuilds, refreshes HotkeyService)
```

## Error handling

- Scanner: `try?` on FileManager enumeration; missing roots are silently
  skipped. A bundle without a `bundleIdentifier` is skipped.
- Sheet: if `scan()` returns empty (impossible in practice on macOS), show the
  empty-state localized string.
- Toggle: no changes. Finder reuses `AppSwitcher.toggle` — `isActive` toggles
  hide; `openApplication` activates. macOS 14+ behavior is uniform across
  apps.

## Testing

Manual verification (no automated UI tests in this project):

1. Launch via `swift run AnyDoor`. Open Settings → 面板.
2. Click "+". Sheet appears with searchable list. Verify Finder, System
   Settings, Calculator, App Store, and at least one third-party app are
   present.
3. Search "find" → only Finder remains. Select Finder. Sheet dismisses.
4. New row appears in App Shortcuts with Finder icon + "未设置" hotkey state.
5. Record a hotkey (e.g. ⌃⌥⌘F). Press it: Finder activates. Press again:
   Finder hides.
6. Reopen the picker — Finder no longer appears in the list (filtered).
7. Restart `swift run AnyDoor`. Finder shortcut persists; hotkey still
   toggles.
8. Repeat with `/System/Applications/Calculator.app` and a non-system app to
   ensure regression coverage.

Build:

```bash
swift build
```

must succeed warning-free for the new files.

## Files touched

- `Sources/AnyDoor/Services/InstalledAppsScanner.swift` (new)
- `Sources/AnyDoor/Views/AppPickerSheet.swift` (new)
- `Sources/AnyDoor/Views/PanelSettingsView.swift` (replace `addApp()` body,
  add `@State`, attach `.sheet`)
- `Sources/AnyDoor/Utilities/L10n.swift` (3 new cases)
- `Sources/AnyDoor/Resources/Localizable.xcstrings` (3 new entries)

## Out of scope / deferred

- Bookmark-based picker for apps outside scanned roots (e.g. `~/Downloads`).
  Users with unusual install locations can still hit the limit; we'll add a
  "Browse…" escape hatch via `NSOpenPanel` only if requested.
- Live filesystem watching for newly-installed apps mid-session.
