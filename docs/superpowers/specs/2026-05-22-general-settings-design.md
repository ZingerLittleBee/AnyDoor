# General Settings: Launch at Login + Accessibility Permission

Date: 2026-05-22
Status: Approved

## Problem

The Settings window's "通用" (General) tab is an empty placeholder
(`GeneralSettingsView` renders only "暂无可配置项"). Two standard options for a
menu bar utility are missing:

1. **Launch at Login** — AnyDoor relies on global hotkeys; users expect it to
   start automatically at login.
2. **Accessibility permission status** — AnyDoor hard-depends on the
   Accessibility permission (CGEvent tap), but nothing in the UI surfaces
   whether it is granted or offers a path to grant it.

## Goals

- Add a Launch at Login toggle to the General tab.
- Add an Accessibility permission row that shows live status and runs a guided
  grant flow.
- Keep the General tab visually native (macOS grouped `Form`).

Non-goals: about/version info, other permissions, menu bar icon customization.

## Approach

### Accessibility grant flow

The guided "drag the app icon into System Settings" interaction is provided by
the `AskForPermission` Swift package
(`https://github.com/riko2chen/AskForPermission`). It is added as an SPM
dependency rather than reimplemented or vendored — the package exposes a clean
facade and the interaction itself is ~2000 lines of animation/window-tracking
code that cannot be made meaningfully lighter.

The package is consumed via its `.requestsPermission(_:)` SwiftUI modifier:
AnyDoor draws its own settings row, and the modifier captures the row's screen
rect and runs the package's guided flow on tap. The package's own
`PermissionsView` is not embedded — it is a fixed-size view with its own chrome
that would not blend into a native grouped `Form`.

### .app bundle requirement

The guided flow requires the host process to be a real `.app` bundle (the user
drags the app icon into the System Settings list). Under `swift run` the process
has no bundle, so:

- `AskForPermission.isAvailable` is `false` — the row falls back to a plain
  "打开系统设置" button that deep-links to the Accessibility pane.
- `LaunchAtLogin.isSupported` is `false` — the toggle is disabled with an
  explanatory footer.

Both conditions reduce to "is `Bundle.main.bundleURL` a `.app`".

## Components

### `Package.swift` (modified)

Add the `AskForPermission` dependency, pinned to an exact revision (the repo has
no version tags):

```swift
.package(url: "https://github.com/riko2chen/AskForPermission.git",
         revision: "91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e")
```

Add `AskForPermission` to the `AnyDoor` target's dependencies. The dependency
compiles in its own declared language mode (Swift 5.9); AnyDoor stays on
`.v6`.

### `Services/LaunchAtLogin.swift` (new)

Thin wrapper over `SMAppService.mainApp` (`import ServiceManagement`):

- `static var isSupported: Bool` — `Bundle.main.bundleURL.pathExtension == "app"`.
- `static var isEnabled: Bool` — `SMAppService.mainApp.status == .enabled`.
- `static func setEnabled(_:) throws` — `register()` / `unregister()`.

`SMAppService` calls are synchronous and quick; no actor needed.

### `Views/GeneralSettingsView.swift` (rewritten)

A `Form` with `.formStyle(.grouped)`, two sections:

**启动 (Startup)**
- Toggle "开机时启动 AnyDoor", reflecting `LaunchAtLogin.isEnabled`.
- On change, call `LaunchAtLogin.setEnabled(_:)`. If it throws, revert the
  toggle to the actual `SMAppService` status and log the error.
- When `!LaunchAtLogin.isSupported`: toggle disabled, section footer reads
  "仅在已安装的 AnyDoor.app 中可用".

**权限 (Permissions)**
- One row: SF Symbol + "辅助功能" + a trailing status badge.
- Granted → "✓ 已授权" badge, no action.
- Not granted + `AskForPermission.isAvailable` → a tappable "去授权" element
  carrying `.requestsPermission(.accessibility)`; tapping runs the guided
  flying-card flow.
- Not granted + `!AskForPermission.isAvailable` → a plain "打开系统设置"
  button deep-linking to
  `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility`.

Status is polled every ~1s with a `Timer` while the view is visible (via
`.onAppear`/`.onDisappear`), reading `AXIsProcessTrusted()` so the badge updates
live after the user grants the permission. Reuses `HotkeyService.hasAccessibilityPermission`.

### `AppDelegate` (modified)

Add `AskForPermission.configure(appName: "AnyDoor")` in
`applicationDidFinishLaunching`. The existing launch-time
`requestAccessibilityPermission()` call is left unchanged.

## Error handling

- `LaunchAtLogin.setEnabled` throwing: revert the toggle to the real
  `SMAppService.mainApp.status`, log via `os.Logger`. If `register()` results in
  `.requiresApproval`, the toggle stays off and the user is expected to approve
  in System Settings → General → Login Items (no extra UI for this edge case).
- `AskForPermission.request` returning `.unavailable` is already handled by the
  `isAvailable` branch — the guided element is not shown in that case.

## Testing

`SMAppService` and TCC are system integrations that cannot be meaningfully unit
tested (no fakes worth the indirection — `LaunchAtLogin` is a thin pass-through).
Verification is manual:

- `make install`, toggle Launch at Login on, log out/in, confirm AnyDoor starts.
- With the permission revoked (`tccutil reset Accessibility dev.bybee.AnyDoor`),
  open General settings, confirm the row shows "未授权" and the guided flow runs
  and the badge flips to "已授权" after granting.
- Run via `swift run`, confirm the toggle is disabled with the footer note and
  the permission row shows the "打开系统设置" fallback.

## UI language

All user-facing strings remain Chinese, consistent with the rest of the app.
Code comments, this spec, and commit messages are English.
