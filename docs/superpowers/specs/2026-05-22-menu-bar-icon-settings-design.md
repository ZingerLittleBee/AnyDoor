# Menu Bar Icon Settings — Design

## Goal

Add two user-facing controls to the General settings tab:

1. **Show menu bar icon** — toggle the visibility of AnyDoor's menu bar item.
2. **Menu bar icon** — pick which system SF Symbol the menu bar item displays.

## Context

- `MenuBarExtra` is declared in `Sources/AnyDoor/AnyDoor.swift` with a hardcoded
  `systemImage: "door.left.hand.open"`.
- The app uses the `.accessory` activation policy: no Dock icon. The menu bar
  item is the only entry point to the panel and the Settings window.
- Settings live under the "通用" (General) tab — `GeneralSettingsView`.
- The project persists relational data (`KeyBinding`, `BuiltinPreference`) in
  SwiftData, but already uses `UserDefaults` for simpler state (`PortInventory`).

## Decisions

### Storage: `@AppStorage` / UserDefaults

The two preferences are scalars (a `Bool` and a `String`), not relational data.
`@AppStorage` lets the `App` struct read them directly and re-render
`MenuBarExtra` on change. Adding a SwiftData `@Model` would require a schema
change to `ModelContainer` and cross-context reads — overkill here.

Keys:

| Key | Type | Default |
|-----|------|---------|
| `menuBar.iconVisible` | `Bool` | `true` |
| `menuBar.iconName` | `String` | `door.left.hand.open` |

The `iconName` default matches the current hardcoded value, so existing
installs see no change.

### Icon picker UI: horizontal swatch row

Only ~6 door-themed icons are offered. A horizontal row of selectable icon
buttons shows every option at once, which suits "pick an icon" better than a
`.menu` Picker that hides options behind a click.

### Re-access fallback when the icon is hidden

When `menuBar.iconVisible` is `false`, the menu bar item disappears entirely.
Because the app stays `.accessory` (no Dock icon), the user would otherwise
have no way back into Settings.

Fallback: implement `applicationShouldHandleReopen(_:hasVisibleWindows:)` in
`AppDelegate`. Re-launching AnyDoor from Finder/Spotlight while it is already
running — and has no visible window — re-opens the Settings window via the
`showSettingsWindow:` action. The activation policy stays `.accessory`; no Dock
icon is ever shown.

## Components

### `MenuBarIcon` (new, `Sources/AnyDoor/Models/`)

A small value type that owns:

- The `UserDefaults` key constants (`menuBar.iconVisible`, `menuBar.iconName`).
- The default icon name (`door.left.hand.open`).
- The ordered list of selectable icons (SF Symbol names).

Icon set (system SF Symbols, door theme, on-brand with "AnyDoor"):

```
door.left.hand.open
door.left.hand.closed
door.right.hand.open
door.sliding.right.hand.open
door.garage.open
door.french.open
```

This type is consumed only by `GeneralSettingsView` (for the picker) and
referenced by `AnyDoorApp` (for the key/default constants).

### `AnyDoorApp` (modified, `AnyDoor.swift`)

- Add `@AppStorage` properties for `iconVisible` and `iconName`, using the
  `MenuBarIcon` key constants and defaults.
- Change the `MenuBarExtra` initializer to:

  ```swift
  MenuBarExtra("AnyDoor", systemImage: iconName, isInserted: $iconVisible)
  ```

  When the stored values change, the `App` body recomputes: `MenuBarExtra`
  swaps its symbol and inserts/removes itself from the menu bar.

### `GeneralSettingsView` (modified)

Add a new `Section("菜单栏")` above the existing permissions section:

- `Toggle("显示菜单栏图标", isOn:)` bound to `@AppStorage("menuBar.iconVisible")`.
- A labeled row "菜单栏图标" containing the horizontal icon swatch row, bound to
  `@AppStorage("menuBar.iconName")`. Each swatch is a tappable
  `Image(systemName:)`; the selected swatch is highlighted (accent-tinted
  background / border). The whole row is `.disabled` when the toggle is off.

### `AppDelegate` (modified)

Add:

```swift
func applicationShouldHandleReopen(_ sender: NSApplication,
                                   hasVisibleWindows flag: Bool) -> Bool {
    if !flag {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    return true
}
```

This opens Settings whenever the app is re-launched with no visible window —
the path back in after the menu bar icon is hidden.

## Data Flow

1. User toggles "显示菜单栏图标" or picks an icon in `GeneralSettingsView`.
2. `@AppStorage` writes the value to `UserDefaults`.
3. `AnyDoorApp`'s `@AppStorage` observes the change; the `App` body recomputes.
4. `MenuBarExtra` updates its `systemImage` / `isInserted` state — the menu bar
   icon changes or disappears immediately.

## Error Handling

- No failure paths: `UserDefaults` reads/writes do not throw.
- Defaults guarantee a valid icon name and a visible icon on first launch and
  if the stored value is ever missing.
- If a stored `iconName` is somehow not in the offered set, the swatch row
  simply shows no selection; the `MenuBarExtra` still renders whatever symbol
  string is stored. (Not expected in practice — the picker only writes known
  values.)

## Testing

Manual verification (no automated UI tests in this project):

- Toggle off → menu bar icon disappears; toggle on → it returns.
- Pick each icon → menu bar symbol updates immediately.
- With the icon hidden, re-launch AnyDoor from Finder → Settings window opens.
- Restart the app → chosen icon and visibility persist.
- Fresh install (no stored values) → icon is visible and shows
  `door.left.hand.open`.

## Out of Scope

- Custom / user-supplied images for the menu bar icon.
- Showing a Dock icon as an alternative entry point.
- Any change to the menu bar panel content or the Settings tab layout beyond
  the new section.
