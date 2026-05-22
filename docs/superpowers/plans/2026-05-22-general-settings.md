# General Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build out the empty "通用" Settings tab with a Launch at Login toggle and an Accessibility permission row backed by the AskForPermission guided grant flow.

**Architecture:** A new `LaunchAtLogin` enum wraps `SMAppService.mainApp`. `GeneralSettingsView` is rewritten as a native grouped `Form`. The Accessibility row uses the `AskForPermission` SPM package's `.requestsPermission(.accessibility)` modifier for the guided flying-card flow, falling back to a plain System Settings deep-link when the process is not a `.app` bundle.

**Tech Stack:** Swift 6.2, SwiftUI, `ServiceManagement` (`SMAppService`), `AskForPermission` (SPM dependency).

**Testing note:** `SMAppService` and TCC are system integrations with no meaningful unit-test surface (per the spec). Each task is verified with `swift build`; Task 5 is a manual verification checklist.

---

### Task 1: Add the AskForPermission dependency

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Replace `Package.swift` with the dependency-aware version**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnyDoor",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(
            url: "https://github.com/riko2chen/AskForPermission.git",
            revision: "91f4dde33f9f5dd58a89d72f3f05aa4b149a1f0e"
        ),
    ],
    targets: [
        .executableTarget(
            name: "AnyDoor",
            dependencies: [
                .product(name: "AskForPermission", package: "AskForPermission"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "AnyDoorTests",
            dependencies: ["AnyDoor"],
            resources: [.process("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
```

- [ ] **Step 2: Resolve and build**

Run: `swift build`
Expected: SwiftPM fetches `AskForPermission` from GitHub (needs network, first run is slower), then `Build complete!`. The unchanged `AnyDoor` sources still compile because nothing imports the new module yet.

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: add AskForPermission dependency"
```

(`Package.resolved` is created/updated by `swift build` — include it so the pinned revision is reproducible.)

---

### Task 2: Add the LaunchAtLogin service

**Files:**
- Create: `Sources/AnyDoor/Services/LaunchAtLogin.swift`

- [ ] **Step 1: Create `LaunchAtLogin.swift`**

```swift
import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the launch-at-login toggle.
///
/// Only meaningful when AnyDoor runs as an installed `.app` bundle. Under
/// `swift run` the process has no bundle, so `isSupported` is false and the
/// settings toggle stays disabled.
enum LaunchAtLogin {
    /// True only when the host process is a real `.app` bundle.
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/LaunchAtLogin.swift
git commit -m "feat(settings): add LaunchAtLogin service wrapper"
```

---

### Task 3: Configure AskForPermission at launch

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Add the import**

In `Sources/AnyDoor/AppDelegate.swift`, add `import AskForPermission` to the import block. The block becomes:

```swift
import Cocoa
import SwiftData
import OSLog
import AskForPermission
```

- [ ] **Step 2: Call `configure` in `applicationDidFinishLaunching`**

In `applicationDidFinishLaunching(_:)`, add the `configure` call immediately after the activation-policy line. The start of the method becomes:

```swift
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AskForPermission.configure(appName: "AnyDoor")

        // Run migrations / seeding on the main context
        let context = modelContainer.mainContext
```

Leave the rest of the method (including the existing `requestAccessibilityPermission()` call) unchanged.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(settings): configure AskForPermission at launch"
```

---

### Task 4: Rewrite GeneralSettingsView

**Files:**
- Modify (full rewrite): `Sources/AnyDoor/Views/GeneralSettingsView.swift`

- [ ] **Step 1: Replace `GeneralSettingsView.swift` with the real settings form**

```swift
import SwiftUI
import AppKit
import OSLog
import AskForPermission

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "settings")

@MainActor
struct GeneralSettingsView: View {
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission

    var body: some View {
        Form {
            Section {
                Toggle("开机时启动 AnyDoor", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isSupported)
                    .onChange(of: launchAtLogin) { _, newValue in
                        // Skip the echo from our own revert assignment below.
                        guard newValue != LaunchAtLogin.isEnabled else { return }
                        do {
                            try LaunchAtLogin.setEnabled(newValue)
                        } catch {
                            logger.error("LaunchAtLogin.setEnabled(\(newValue)) failed: \(error)")
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
            } header: {
                Text("启动")
            } footer: {
                if !LaunchAtLogin.isSupported {
                    Text("仅在已安装的 AnyDoor.app 中可用")
                }
            }

            Section("权限") {
                accessibilityRow
            }
        }
        .formStyle(.grouped)
        // Poll while the tab is visible so the badge updates live after the
        // user grants the permission in System Settings.
        .task {
            while !Task.isCancelled {
                accessibilityGranted = HotkeyService.hasAccessibilityPermission
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder
    private var accessibilityRow: some View {
        HStack {
            Label("辅助功能", systemImage: "accessibility")
            Spacer()
            if accessibilityGranted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if AskForPermission.isAvailable {
                // Plain Text (not a Button) per AskForPermission guidance —
                // the modifier owns the tap and runs the guided flight flow.
                Text("去授权")
                    .foregroundStyle(Color.accentColor)
                    .requestsPermission(.accessibility)
            } else {
                Button("打开系统设置", action: openAccessibilitySettings)
            }
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift
git commit -m "feat(settings): build out general settings tab"
```

---

### Task 5: Manual verification

**Files:** none (verification only — no commit)

These cannot be automated (`SMAppService`, TCC, login cycle). Run them and confirm each.

- [ ] **Step 1: Dev-mode fallback check**

Run: `swift run AnyDoor`
Open the menu bar panel → 设置 → 通用 tab. Confirm:
- The "开机时启动 AnyDoor" toggle is disabled, with footer "仅在已安装的 AnyDoor.app 中可用".
- The 辅助功能 row shows either "已授权" or, if not granted, a "打开系统设置" button (the `swift run` process is not a `.app`, so the guided flow is unavailable).

Quit the app when done.

- [ ] **Step 2: Installed-app guided flow check**

Run: `make install`, then launch `/Applications/AnyDoor.app`.
Revoke the permission first: `tccutil reset Accessibility dev.bybee.AnyDoor`.
Open 设置 → 通用. Confirm:
- The 辅助功能 row shows "去授权".
- Clicking "去授权" opens System Settings' Accessibility pane and runs the AskForPermission guided flying-card flow.
- After granting, the badge flips to "已授权" within ~1s without reopening the window.

- [ ] **Step 3: Launch at Login check**

In the installed app's 通用 tab, toggle "开机时启动 AnyDoor" on.
Confirm: `SMAppService` registered it — verify via System Settings → General → Login Items, or `sfltool dumpbtm | grep -i anydoor`.
Toggle it off and confirm it is removed.
