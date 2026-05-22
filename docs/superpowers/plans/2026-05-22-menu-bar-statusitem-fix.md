# Menu Bar Status Item Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the startup freeze by replacing SwiftUI's `MenuBarExtra` with a hand-managed `NSStatusItem`, while keeping the show/hide-icon and icon-picker features working.

**Architecture:** Binding `MenuBarExtra(isInserted:)` to a `false` value drives an infinite `scenesDidChange → makeMainMenu → invalidateProperties` transaction storm on macOS 26 that pegs the main thread at ~100% CPU (proven by `sample` + a content-independent bisection). `SceneBuilder` does not support `if`, so the `MenuBarExtra` scene cannot be conditionally omitted. The fix: drop `MenuBarExtra` entirely, leave only the `Settings` scene, and let a new `@MainActor` `MenuBarController` own an `NSStatusItem` plus a borderless `NSPanel` that hosts `MenuBarView`. `NSStatusItem.isVisible` toggles the icon with no scene-graph involvement.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI (`Settings` scene, `NSHostingController`), AppKit (`NSStatusItem`, `NSPanel`, `NSEvent` monitors), SwiftData, SPM.

---

## File Structure

- **Modify** `Sources/AnyDoor/Models/MenuBarIcon.swift` — add self-contained `isVisible` / `currentName` accessors that read `UserDefaults` for non-SwiftUI consumers.
- **Create** `Sources/AnyDoor/Services/MenuBarController.swift` — owns the `NSStatusItem` and the click-to-open panel; outside-click dismissal.
- **Modify** `Sources/AnyDoor/Views/MenuBarView.swift` — add an `onRequestClose` callback; replace `SettingsLink` (scene-only API) with a plain button.
- **Modify** `Sources/AnyDoor/AnyDoor.swift` — reduce `App.body` to just the `Settings` scene.
- **Modify** `Sources/AnyDoor/AppDelegate.swift` — instantiate `MenuBarController`, observe `UserDefaults` changes to keep the status item synced.
- **Modify** `Tests/AnyDoorTests/MenuBarIconTests.swift` — cover the new accessors.

**Out of scope (follow-up):** `MenuBarView.swift:6` `@State private var popover = HoverPopover { ... }` allocates an `NSWindow` inside a `@State` initializer (a SwiftUI anti-pattern — the initializer expression re-runs on every `MenuBarView.init`). It is an amplifier of the old freeze, not its cause, and is left for a separate change.

---

## Task 1: `MenuBarIcon` preference accessors

`MenuBarController` is not a SwiftUI view, so it cannot use `@AppStorage`. Give `MenuBarIcon` plain accessors that read `UserDefaults` and encapsulate the same defaults `@AppStorage` uses (`true` / `defaultName`).

**Files:**
- Modify: `Sources/AnyDoor/Models/MenuBarIcon.swift`
- Test: `Tests/AnyDoorTests/MenuBarIconTests.swift`

- [ ] **Step 1: Write the failing tests**

In `Tests/AnyDoorTests/MenuBarIconTests.swift`, add these two methods inside the `MenuBarIconTests` class (after the existing `testStorageKeysAreDistinct`):

```swift
    func testIsVisibleDefaultsToTrueWhenUnset() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MenuBarIcon.visibilityKey)
        defaults.removeObject(forKey: MenuBarIcon.visibilityKey)
        defer { if let original { defaults.set(original, forKey: MenuBarIcon.visibilityKey) } }

        XCTAssertTrue(MenuBarIcon.isVisible, "Unset visibility must read as true")
    }

    func testCurrentNameFallsBackToDefaultWhenUnset() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MenuBarIcon.nameKey)
        defaults.removeObject(forKey: MenuBarIcon.nameKey)
        defer { if let original { defaults.set(original, forKey: MenuBarIcon.nameKey) } }

        XCTAssertEqual(MenuBarIcon.currentName, MenuBarIcon.defaultName)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MenuBarIconTests`
Expected: FAIL — compile error, `type 'MenuBarIcon' has no member 'isVisible'`.

- [ ] **Step 3: Add the accessors**

In `Sources/AnyDoor/Models/MenuBarIcon.swift`, add `import Foundation` as the first line (the file currently has no import), then add these computed properties inside the `enum MenuBarIcon`, after the `options` array:

```swift
    /// Current visibility preference. Returns `true` when the key is unset so
    /// fresh installs show the icon — mirrors the `@AppStorage` default.
    static var isVisible: Bool {
        UserDefaults.standard.object(forKey: visibilityKey) as? Bool ?? true
    }

    /// Current icon SF Symbol name, falling back to `defaultName` when unset.
    static var currentName: String {
        UserDefaults.standard.string(forKey: nameKey) ?? defaultName
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MenuBarIconTests`
Expected: PASS — 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/MenuBarIcon.swift Tests/AnyDoorTests/MenuBarIconTests.swift
git commit -m "feat(menubar): add UserDefaults accessors to MenuBarIcon"
```

---

## Task 2: Replace `MenuBarExtra` with `MenuBarController`

This is the atomic refactor: four files change together and the build is verified once at the end.

**Files:**
- Create: `Sources/AnyDoor/Services/MenuBarController.swift`
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`
- Modify: `Sources/AnyDoor/AnyDoor.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Create `MenuBarController`**

Create `Sources/AnyDoor/Services/MenuBarController.swift`:

```swift
import AppKit
import SwiftData
import SwiftUI

/// Owns the menu bar status item and the click-to-open panel.
///
/// Replaces SwiftUI's `MenuBarExtra`: binding `MenuBarExtra(isInserted:)` to a
/// `false` value drives an infinite `scenesDidChange` transaction storm on
/// macOS 26 that pegs the main thread. Driving `NSStatusItem.isVisible`
/// directly toggles the icon with no scene-graph involvement.
@MainActor
final class MenuBarController {
    private let modelContainer: ModelContainer

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingController: NSHostingController<AnyView>?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Create the status item. Call once, after launch.
    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.iconImage(named: MenuBarIcon.currentName)
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        item.isVisible = MenuBarIcon.isVisible
        statusItem = item
    }

    /// Re-read the icon preferences and update the status item. Cheap enough to
    /// call on every `UserDefaults.didChangeNotification`.
    func syncFromPreferences() {
        guard let statusItem else { return }
        statusItem.isVisible = MenuBarIcon.isVisible
        statusItem.button?.image = Self.iconImage(named: MenuBarIcon.currentName)
        if !MenuBarIcon.isVisible { hidePanel() }
    }

    // MARK: - Panel

    @objc private func statusItemClicked() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }

        let hosting = NSHostingController(
            rootView: AnyView(
                MenuBarView(onRequestClose: { [weak self] in self?.hidePanel() })
                    .modelContainer(modelContainer)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        hostingController = hosting

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        self.panel = panel

        // Size to the SwiftUI content before showing to avoid a resize flash.
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            panel.setContentSize(fitting)
        }

        positionPanel(panel, under: button)
        panel.orderFrontRegardless()
        button.highlight(true)
        installClickMonitors()
    }

    private func hidePanel() {
        removeClickMonitors()
        statusItem?.button?.highlight(false)
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel = nil
        hostingController = nil
    }

    /// Anchor the panel's top-right corner just below the status item.
    private func positionPanel(_ panel: NSPanel, under button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonInScreen = buttonWindow.convertToScreen(
            button.convert(button.bounds, to: nil)
        )
        let size = panel.frame.size
        var origin = NSPoint(
            x: buttonInScreen.maxX - size.width,
            y: buttonInScreen.minY - size.height - 4
        )
        if let screen = buttonWindow.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Outside-click dismissal

    private func installClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                let clickWindow = event.window
                // Keep the panel open for clicks inside it, inside a hover
                // side-popover, or on the status item (its action toggles).
                if clickWindow == self.panel
                    || clickWindow is KeyableHoverPanel
                    || clickWindow == self.statusItem?.button?.window {
                    return event
                }
                self.hidePanel()
                return event
            }
        }
    }

    private func removeClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
    }

    // MARK: - Icon image

    private static func iconImage(named name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "AnyDoor")
        image?.isTemplate = true
        return image
    }
}
```

- [ ] **Step 2: Add the `onRequestClose` callback to `MenuBarView`**

In `Sources/AnyDoor/Views/MenuBarView.swift`, add a stored property as the first member of the struct. The struct currently begins:

```swift
struct MenuBarView: View {
    @State private var panel = PanelStore.shared
```

Change it to:

```swift
struct MenuBarView: View {
    /// Invoked by the footer's Settings button so the controller can dismiss
    /// the panel before the Settings window opens.
    let onRequestClose: () -> Void

    @State private var panel = PanelStore.shared
```

- [ ] **Step 3: Replace `SettingsLink` in the `MenuBarView` footer**

`SettingsLink` only resolves inside a SwiftUI scene; `MenuBarView` is now hosted in a plain `NSHostingController`, so it must open Settings imperatively. In the same file, the footer currently reads:

```swift
            // Footer
            HStack(spacing: 8) {
                SettingsLink { Label("设置", systemImage: "gear") }
                    .buttonStyle(.glass)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApplication.shared.activate()
                    })
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }.buttonStyle(.glass)
                Spacer()
            }
```

Replace that exact block with:

```swift
            // Footer
            HStack(spacing: 8) {
                Button {
                    onRequestClose()
                    NSApp.activate()
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Label("设置", systemImage: "gear")
                }
                .buttonStyle(.glass)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("退出", systemImage: "power")
                }.buttonStyle(.glass)
                Spacer()
            }
```

- [ ] **Step 4: Reduce `AnyDoorApp` to the `Settings` scene**

Overwrite `Sources/AnyDoor/AnyDoor.swift` with:

```swift
import SwiftUI
import SwiftData

@main
struct AnyDoorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The menu bar item is owned by `MenuBarController` (see AppDelegate),
        // not a SwiftUI `MenuBarExtra`. Only the Settings scene lives here.
        Settings {
            SettingsView()
                .modelContainer(appDelegate.modelContainer)
        }
    }
}
```

- [ ] **Step 5: Wire `MenuBarController` into `AppDelegate`**

In `Sources/AnyDoor/AppDelegate.swift`, add two stored properties. The class currently begins:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer
```

Change it to:

```swift
final class AppDelegate: NSObject, NSApplicationDelegate {
    let modelContainer: ModelContainer
    private var menuBarController: MenuBarController?
    private var defaultsObserver: NSObjectProtocol?
```

Then, in `applicationDidFinishLaunching(_:)`, the method currently ends:

```swift
        HotkeyService.shared.start()
        PanelStore.shared.rebuildHotkeySnapshots()
    }
```

Replace that exact text with:

```swift
        HotkeyService.shared.start()
        PanelStore.shared.rebuildHotkeySnapshots()

        // Menu bar status item. Replaces SwiftUI `MenuBarExtra`, whose
        // `isInserted: false` state infinite-loops the scene graph on macOS 26.
        let menuBar = MenuBarController(modelContainer: modelContainer)
        menuBar.install()
        menuBarController = menuBar
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak menuBar] _ in
            MainActor.assumeIsolated { menuBar?.syncFromPreferences() }
        }
    }
```

The existing `applicationShouldHandleReopen(_:hasVisibleWindows:)` stays unchanged — when the icon is hidden it is still the only way to bring Settings back, and it is now safe (no `MenuBarExtra` to loop).

- [ ] **Step 6: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors. Pre-existing `nonisolated(unsafe)` warnings in `HoverPopover.swift` are unrelated and acceptable.

If strict-concurrency rejects the `NSEvent` monitor closures, mirror the existing pattern in `HoverPopover.swift:58-67` (`[weak self]` capture + `MainActor.assumeIsolated`) — the design above already uses it.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/MenuBarController.swift Sources/AnyDoor/Views/MenuBarView.swift Sources/AnyDoor/AnyDoor.swift Sources/AnyDoor/AppDelegate.swift
git commit -m "fix(menubar): replace MenuBarExtra with a managed NSStatusItem

Binding MenuBarExtra(isInserted:) to a false value drives an infinite
scenesDidChange transaction storm on macOS 26, freezing the app at launch
whenever the icon preference is off. SceneBuilder has no conditional, so
the scene cannot be omitted; manage NSStatusItem directly instead."
```

---

## Task 3: Verification

**Files:** none (build, sample, manual run). Run from the repo root.

- [ ] **Step 1: Full test suite**

Run: `swift test`
Expected: all tests pass, including the 5 `MenuBarIconTests`.

- [ ] **Step 2: Regression check — the freeze is gone (icon hidden)**

This is the core check. Reproduce the original failure condition and confirm CPU stays idle:

```bash
swift build
defaults write AnyDoor menuBar.iconVisible -bool false
.build/debug/AnyDoor &
PID=$!
sleep 6
ps -p $PID -o pid,%cpu,state
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
```

Expected: `%cpu` is near `0.0` and state is `S`/`SN` (sleeping). Before the fix this was 43–97% and `RN` (running). If `%cpu` is still high, STOP — the fix did not work; do not proceed.

- [ ] **Step 3: Regression check — icon visible**

```bash
defaults write AnyDoor menuBar.iconVisible -bool true
.build/debug/AnyDoor &
PID=$!
sleep 6
ps -p $PID -o pid,%cpu,state
kill $PID 2>/dev/null; sleep 1; kill -9 $PID 2>/dev/null
```

Expected: `%cpu` near `0.0`.

- [ ] **Step 4: Manual UI verification**

Run `swift run AnyDoor`. Verify:
- The menu bar shows the `door.left.hand.open` icon.
- Clicking the icon opens the panel anchored below it; the icon highlights while open.
- Clicking inside the panel keeps it open; clicking elsewhere (another app, or empty desktop) closes it.
- Hovering the "应用快捷键" / submenu rows still opens the side popover (the `HoverPopover` interaction is intact).
- Footer "设置" opens the Settings window and closes the panel; "退出" quits.
- In Settings → 通用 → 菜单栏: toggling "显示菜单栏图标" off removes the icon and leaves the rest of the app responsive; toggling it on restores the icon. Picking a different icon swatch updates the menu bar icon.
- Quit, relaunch — the chosen icon and visibility persist.

- [ ] **Step 5: Restore defaults and clean up**

```bash
defaults write AnyDoor menuBar.iconVisible -bool true
pkill -9 -f AnyDoor 2>/dev/null; pgrep -fl AnyDoor
```

Expected: `pgrep` prints nothing (the `grep`/`pgrep` line itself excluded).
