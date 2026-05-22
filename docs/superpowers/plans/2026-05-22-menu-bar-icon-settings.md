# Menu Bar Icon Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user show/hide AnyDoor's menu bar icon and pick which system SF Symbol it displays, from the General settings tab.

**Architecture:** Two scalar preferences (`Bool` + `String`) stored in `UserDefaults` via `@AppStorage`. The `App` struct reads them to drive `MenuBarExtra`'s `isInserted` binding and dynamic `systemImage`. A new `MenuBarIcon` value type owns the storage keys, default, and icon catalog. `AppDelegate` gains `applicationShouldHandleReopen` so re-launching the app re-opens Settings after the icon is hidden.

**Tech Stack:** Swift 6.2, SwiftUI (`MenuBarExtra`, `@AppStorage`), AppKit (`NSApplicationDelegate`), XCTest, SPM.

---

## File Structure

- **Create** `Sources/AnyDoor/Models/MenuBarIcon.swift` — storage key constants, default icon name, ordered SF Symbol catalog.
- **Create** `Tests/AnyDoorTests/MenuBarIconTests.swift` — unit tests for the catalog invariants.
- **Modify** `Sources/AnyDoor/AnyDoor.swift` — add `@AppStorage` properties, change `MenuBarExtra` to use dynamic `systemImage` + `isInserted`.
- **Modify** `Sources/AnyDoor/AppDelegate.swift` — add `applicationShouldHandleReopen`.
- **Modify** `Sources/AnyDoor/Views/GeneralSettingsView.swift` — add a "菜单栏" section with the visibility toggle and icon swatch row.

---

## Task 1: `MenuBarIcon` catalog type

**Files:**
- Create: `Sources/AnyDoor/Models/MenuBarIcon.swift`
- Test: `Tests/AnyDoorTests/MenuBarIconTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/MenuBarIconTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class MenuBarIconTests: XCTestCase {
    func testDefaultNameIsSelectable() {
        XCTAssertTrue(
            MenuBarIcon.options.contains(MenuBarIcon.defaultName),
            "Default icon must appear in the offered options so the picker can show it as selected"
        )
    }

    func testOptionsHaveNoDuplicates() {
        XCTAssertEqual(
            Set(MenuBarIcon.options).count,
            MenuBarIcon.options.count,
            "Icon options must be unique"
        )
    }

    func testStorageKeysAreDistinct() {
        XCTAssertNotEqual(MenuBarIcon.visibilityKey, MenuBarIcon.nameKey)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MenuBarIconTests`
Expected: FAIL — compile error, `cannot find 'MenuBarIcon' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Sources/AnyDoor/Models/MenuBarIcon.swift`:

```swift
import Foundation

/// Storage keys, default value, and the catalog of SF Symbols offered for the
/// menu bar icon. Consumed by `AnyDoorApp` (keys + default) and
/// `GeneralSettingsView` (the picker).
enum MenuBarIcon {
    /// UserDefaults key for whether the menu bar item is shown.
    static let visibilityKey = "menuBar.iconVisible"

    /// UserDefaults key for the selected SF Symbol name.
    static let nameKey = "menuBar.iconName"

    /// Default icon — matches the symbol the app originally shipped with.
    static let defaultName = "door.left.hand.open"

    /// Ordered SF Symbol names offered in the picker. Door theme, on-brand
    /// with the "AnyDoor" name.
    static let options: [String] = [
        "door.left.hand.open",
        "door.left.hand.closed",
        "door.right.hand.open",
        "door.sliding.right.hand.open",
        "door.garage.open",
        "door.french.open",
    ]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MenuBarIconTests`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/MenuBarIcon.swift Tests/AnyDoorTests/MenuBarIconTests.swift
git commit -m "feat(menubar): add MenuBarIcon catalog and storage keys"
```

---

## Task 2: Dynamic menu bar icon and visibility

**Files:**
- Modify: `Sources/AnyDoor/AnyDoor.swift`

- [ ] **Step 1: Replace the file contents**

Overwrite `Sources/AnyDoor/AnyDoor.swift` with:

```swift
import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @AppStorage(MenuBarIcon.visibilityKey) private var iconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var iconName = MenuBarIcon.defaultName

    var body: some Scene {
        MenuBarExtra("AnyDoor", systemImage: iconName, isInserted: $iconVisible) {
            MenuBarView()
                .modelContainer(appDelegate.modelContainer)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
        }
    }
}
```

Note: `@AppStorage` defaults (`true`, `MenuBarIcon.defaultName`) apply only when
the key is absent, so existing installs and fresh launches both start with a
visible `door.left.hand.open` icon. When either stored value changes, the `App`
body recomputes and `MenuBarExtra` swaps its symbol or inserts/removes itself.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/AnyDoor.swift
git commit -m "feat(menubar): drive menu bar icon from stored preferences"
```

---

## Task 3: Re-open Settings after the icon is hidden

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Add the reopen handler**

In `Sources/AnyDoor/AppDelegate.swift`, insert this method immediately after the
existing `applicationWillTerminate(_:)` method (which currently ends at the
`}` closing the `HotkeyService.shared.stop()` body):

```swift
    /// When the icon is hidden the menu bar item disappears and the app keeps
    /// the `.accessory` policy (no Dock icon). Re-launching AnyDoor from
    /// Finder/Spotlight lands here; with no visible window, re-open Settings so
    /// the user can turn the icon back on.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        return true
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(menubar): reopen Settings on relaunch when icon is hidden"
```

---

## Task 4: Menu bar section in General settings

**Files:**
- Modify: `Sources/AnyDoor/Views/GeneralSettingsView.swift`

- [ ] **Step 1: Add the `@AppStorage` properties**

In `Sources/AnyDoor/Views/GeneralSettingsView.swift`, the struct currently
declares three `@State` properties:

```swift
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission
    @State private var automationGranted = false
```

Add two `@AppStorage` properties directly below them:

```swift
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var accessibilityGranted = HotkeyService.hasAccessibilityPermission
    @State private var automationGranted = false
    @AppStorage(MenuBarIcon.visibilityKey) private var menuBarIconVisible = true
    @AppStorage(MenuBarIcon.nameKey) private var menuBarIconName = MenuBarIcon.defaultName
```

- [ ] **Step 2: Add the menu bar section to the Form**

In the same file, the `Form` currently contains the `启动` section followed by
the `权限` section. Insert a new section between them. The `启动` section ends
with:

```swift
            } header: {
                Text("启动")
            }

            Section("权限") {
```

Replace that exact text with:

```swift
            } header: {
                Text("启动")
            }

            Section("菜单栏") {
                Toggle("显示菜单栏图标", isOn: $menuBarIconVisible)

                LabeledContent("菜单栏图标") {
                    HStack(spacing: 8) {
                        ForEach(MenuBarIcon.options, id: \.self) { name in
                            iconSwatch(name)
                        }
                    }
                }
                .disabled(!menuBarIconVisible)
            }

            Section("权限") {
```

- [ ] **Step 3: Add the `iconSwatch` helper**

In the same file, add this method inside the struct, immediately before the
existing `private func openAccessibilitySettings()` method:

```swift
    @ViewBuilder
    private func iconSwatch(_ name: String) -> some View {
        let isSelected = menuBarIconName == name
        Button {
            menuBarIconName = name
        } label: {
            Image(systemName: name)
                .font(.system(size: 16))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .help(name)
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/GeneralSettingsView.swift
git commit -m "feat(settings): add menu bar icon visibility and picker"
```

---

## Task 5: Manual verification

**Files:** none (manual run).

- [ ] **Step 1: Build and run**

Run: `swift run AnyDoor`
Expected: app launches, menu bar shows the `door.left.hand.open` icon.

- [ ] **Step 2: Verify the icon picker**

Open Settings → 通用 tab. In the new "菜单栏" section, click each icon swatch.
Expected: the selected swatch highlights with the accent color, and the menu
bar icon updates to the chosen symbol immediately.

- [ ] **Step 3: Verify hide / show**

Toggle "显示菜单栏图标" off.
Expected: the menu bar icon disappears, and the icon swatch row becomes
disabled (greyed out). Toggle it back on — the icon returns.

- [ ] **Step 4: Verify the reopen fallback**

With "显示菜单栏图标" still off and the Settings window closed, re-launch
AnyDoor from Finder or Spotlight (the running instance, not a second copy).
Expected: the Settings window re-opens so the icon can be turned back on.

- [ ] **Step 5: Verify persistence**

Quit AnyDoor and run `swift run AnyDoor` again.
Expected: the previously chosen icon and visibility state are restored.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all tests pass, including `MenuBarIconTests`.
