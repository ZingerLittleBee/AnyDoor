# Display Brightness Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hover-popover "屏幕亮度" panel entry that controls external DDC/CI display brightness on both Intel and Apple Silicon Macs, plus assignable ± hotkeys that fire the native macOS OSD.

**Architecture:** A new `DisplayBrightnessService` (@MainActor @Observable) sits between the SwiftUI hover popover and a `BrightnessController` actor. The controller talks to displays through a `DDCBackend` protocol with two production implementations chosen at compile time: `IntelDDCBackend` (wraps `reitermarkus/DDC.swift`, MIT) on Intel, and a clean-room `Arm64DDCBackend` (calls private `IOAVServiceReadI2C` / `IOAVServiceWriteI2C` symbols) on Apple Silicon. The hover popover plugs into the existing `MenuBarView` hover-routing via a new `HoverPopoverTarget` case. Brightness ± hotkeys are modelled as proper `BuiltinItem` cases with a new `.hiddenHotkey` Kind so they participate in conflict detection without rendering as panel rows.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, IOKit (Intel: `IOKit.i2c`; Apple Silicon: private `IOAVService`), CoreDisplay, AppKit (`NSScreen`, `NSEvent.mouseLocation`), private `OSD.framework`.

**Spec:** [`docs/superpowers/specs/2026-05-24-display-brightness-design.md`](../specs/2026-05-24-display-brightness-design.md)

---

## File Map

### New files

| Path | Responsibility |
|---|---|
| `Sources/AnyDoor/Services/Brightness/DDCBackend.swift` | Protocol + `MockDDCBackend` (always available). |
| `Sources/AnyDoor/Services/Brightness/Arm64DDCBackend.swift` | `#if arch(arm64)` IOAVService clean-room backend. |
| `Sources/AnyDoor/Services/Brightness/IntelDDCBackend.swift` | `#if !arch(arm64)` wraps DDC.swift. |
| `Sources/AnyDoor/Services/Brightness/BrightnessController.swift` | Actor: serializes I2C, exposes probe/read/write. |
| `Sources/AnyDoor/Services/Brightness/DisplayBrightnessService.swift` | @MainActor @Observable: enumerates displays, owns `levels` / `levelGeneration`, debounces writes, handles hotkey bumps. |
| `Sources/AnyDoor/Services/Brightness/OSDBridge.swift` | dlopen-based native OSD trigger; silent no-op on failure. |
| `Sources/AnyDoor/Views/BrightnessPopoverView.swift` | Hover popover content + per-display `DisplayBrightnessCard`. |
| `Tests/AnyDoorTests/BrightnessControllerTests.swift` | Probe / read / write / retry / clamp / normalization via `MockDDCBackend`. |
| `Tests/AnyDoorTests/DisplayBrightnessServiceTests.swift` | Debounce, generation token, nil-baseline backfill, fallback display resolution. |
| `Tests/AnyDoorTests/BuiltinItemBrightnessTests.swift` | New cases + Kind + defaultVisibility. |
| `Tests/AnyDoorTests/BuiltinPreferenceSeederTests.swift` | Seeded `.hiddenHotkey` rows have `isVisible == false`. |

### Modified files

| Path | What changes |
|---|---|
| `Package.swift` | Add `reitermarkus/DDC.swift` dependency (unconditional; arch gating is at source level). |
| `Sources/AnyDoor/Models/BuiltinItem.swift` | New cases `.brightness` / `.brightnessUp` / `.brightnessDown`, new `Kind` cases `.brightnessControl` / `.hiddenHotkey`, `defaultVisibility` property, plus updates to all per-case switches. |
| `Sources/AnyDoor/Models/HotkeyAction.swift` | Add `.brightnessUp` / `.brightnessDown` cases. |
| `Sources/AnyDoor/Services/PanelStore.swift` | `rebuild()` filters `.hiddenHotkey`; `entryUsingHotkey` also scans hidden-hotkey items; `rebuildHotkeySnapshots` emits brightness actions; `dispatch` routes ± to service. |
| `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` | Use `item.defaultVisibility` instead of hardcoded `true`. |
| `Sources/AnyDoor/Views/PanelRowView.swift` | Two switches grow `.brightnessControl` and `.hiddenHotkey` arms. |
| `Sources/AnyDoor/Views/PanelSettingsView.swift` | `typeBadge` and `hotkeyField` switches grow new arms; inline brightness ± recorder below the brightness row. |
| `Sources/AnyDoor/Views/MenuBarView.swift` | `HoverPopoverTarget` gains `.brightnessControl(BuiltinItem)`; `rowView(for:)` registers the trigger; `mountPopoverContent` mounts `BrightnessPopoverView`. |
| `Sources/AnyDoor/AppDelegate.swift` | Build controller + service, call `bootstrap`, schedule background pre-warm refresh. |
| `README.md` / `README.zh-CN.md` | DDC.swift attribution line. |

---

## Task 1 — Add DDC.swift dependency to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1.1: Add dependency and product**

Open `Package.swift`. In the `dependencies:` array (after the Sparkle entry) add:

```swift
.package(
    url: "https://github.com/reitermarkus/DDC.swift",
    from: "0.0.1"
),
```

In the `AnyDoor` executable target's `dependencies:` array add:

```swift
.product(name: "DDC", package: "DDC.swift"),
```

Resulting `targets:` block looks like:

```swift
.executableTarget(
    name: "AnyDoor",
    dependencies: [
        .product(name: "AskForPermission", package: "AskForPermission"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "DDC", package: "DDC.swift"),
    ],
    swiftSettings: [
        .swiftLanguageMode(.v6),
    ]
),
```

Leave the dependency unconditional. Per the spec, `Package.swift` `#if arch(...)` is host-evaluated and would break universal builds.

- [ ] **Step 1.2: Resolve & verify build**

```bash
swift package update DDC.swift
swift build 2>&1 | tail -20
```

Expected: build succeeds (no usage yet, so no source-level errors). `Package.resolved` updates.

- [ ] **Step 1.3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "feat(brightness): add DDC.swift dependency for external display DDC/CI control"
```

---

## Task 2 — Extend `BuiltinItem` with brightness cases, Kind values, and `defaultVisibility`

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Create: `Tests/AnyDoorTests/BuiltinItemBrightnessTests.swift`

- [ ] **Step 2.1: Write the failing tests**

Create `Tests/AnyDoorTests/BuiltinItemBrightnessTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class BuiltinItemBrightnessTests: XCTestCase {
    func testNewCasesExist() {
        XCTAssertNotNil(BuiltinItem(rawValue: "brightness"))
        XCTAssertNotNil(BuiltinItem(rawValue: "brightnessUp"))
        XCTAssertNotNil(BuiltinItem(rawValue: "brightnessDown"))
    }

    func testBrightnessKindIsBrightnessControl() {
        XCTAssertEqual(BuiltinItem.brightness.kind, .brightnessControl)
    }

    func testBumpHotkeysAreHiddenKind() {
        XCTAssertEqual(BuiltinItem.brightnessUp.kind, .hiddenHotkey)
        XCTAssertEqual(BuiltinItem.brightnessDown.kind, .hiddenHotkey)
    }

    func testDefaultVisibilityFalseForHiddenHotkeys() {
        XCTAssertFalse(BuiltinItem.brightnessUp.defaultVisibility)
        XCTAssertFalse(BuiltinItem.brightnessDown.defaultVisibility)
    }

    func testDefaultVisibilityTrueForRegularItems() {
        XCTAssertTrue(BuiltinItem.brightness.defaultVisibility)
        XCTAssertTrue(BuiltinItem.keepAwake.defaultVisibility)
        XCTAssertTrue(BuiltinItem.appShortcuts.defaultVisibility)
        XCTAssertTrue(BuiltinItem.ocr.defaultVisibility)
    }

    func testBrightnessTitleAndSymbol() {
        XCTAssertEqual(BuiltinItem.brightness.title, "屏幕亮度")
        XCTAssertEqual(BuiltinItem.brightness.symbol, "sun.max")
    }

    func testBumpRowsExcludedFromAllCasesIteration() {
        // Sanity: they are in allCases so .allCases iteration in seeder picks them up
        XCTAssertTrue(BuiltinItem.allCases.contains(.brightnessUp))
        XCTAssertTrue(BuiltinItem.allCases.contains(.brightnessDown))
    }
}
```

- [ ] **Step 2.2: Run tests; verify they fail**

```bash
swift test --filter BuiltinItemBrightnessTests 2>&1 | tail -20
```

Expected: compile errors ("type 'BuiltinItem' has no member 'brightness'") or test failures.

- [ ] **Step 2.3: Add the three new cases**

Edit `Sources/AnyDoor/Models/BuiltinItem.swift`. Append three cases to the `enum BuiltinItem` declaration (after line 27 `case qrcode`):

```swift
    case brightness
    case brightnessUp
    case brightnessDown
```

- [ ] **Step 2.4: Add the two new `Kind` cases**

In the `enum Kind: Sendable` block (around line 29) add two cases:

```swift
    enum Kind: Sendable {
        case toggle
        case action
        case submenu
        case brightnessControl
        case hiddenHotkey
    }
```

- [ ] **Step 2.5: Update the `kind` switch**

Update the `kind` computed property switch to route the new cases. The full switch becomes:

```swift
    var kind: Kind {
        switch self {
        case .appShortcuts, .portManager: return .submenu
        case .keepAwake, .muteAudio, .hideDesktopIcons, .showHiddenFiles, .darkMode,
             .hideDock, .autoHideMenuBar, .keyboardLock: return .toggle
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
        case .brightness: return .brightnessControl
        case .brightnessUp, .brightnessDown: return .hiddenHotkey
        }
    }
```

- [ ] **Step 2.6: Add title / symbol / defaultOrder for the new cases**

Update three switches. In `title`, add:

```swift
        case .brightness: return "屏幕亮度"
        case .brightnessUp: return "亮度 +"
        case .brightnessDown: return "亮度 −"
```

In `symbol`, add:

```swift
        case .brightness: return "sun.max"
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
```

In `defaultOrder`, add (placing `.brightness` adjacent to display-related items, sentinel for hidden):

```swift
        case .brightness: return 650
        case .brightnessUp: return 999_998
        case .brightnessDown: return 999_999
```

- [ ] **Step 2.7: Add `defaultVisibility` computed property**

After the `feedbackSound` property (line 155), add:

```swift
    /// Whether this item should default to being shown in the menu bar panel when first seeded.
    /// False only for hidden-hotkey items (brightness ± live on the brightness row only).
    var defaultVisibility: Bool {
        switch self.kind {
        case .toggle, .action, .submenu, .brightnessControl: return true
        case .hiddenHotkey:                                   return false
        }
    }
```

- [ ] **Step 2.8: Run tests**

```bash
swift test --filter BuiltinItemBrightnessTests 2>&1 | tail -20
```

Expected: all 7 tests pass. Note: `swift build` (full) will still fail because exhaustive switches downstream (`PanelRowView`, `PanelSettingsView`) haven't been updated yet. That's intentional — Task 5 fixes them.

- [ ] **Step 2.9: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/BuiltinItemBrightnessTests.swift
git commit -m "feat(brightness): add brightness BuiltinItem cases and Kind values"
```

---

## Task 3 — Update `BuiltinPreferenceSeeder` to use `defaultVisibility`

**Files:**
- Modify: `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift:26-32`
- Create: `Tests/AnyDoorTests/BuiltinPreferenceSeederTests.swift`

- [ ] **Step 3.1: Write the failing test**

Create `Tests/AnyDoorTests/BuiltinPreferenceSeederTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

@MainActor
final class BuiltinPreferenceSeederTests: XCTestCase {
    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            ClipboardHistoryItem.self,
        ])
        let config = ModelConfiguration(
            isStoredInMemoryOnly: true,
            allowsSave: true
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        return container.mainContext
    }

    func testHiddenHotkeyItemsAreSeededInvisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let up = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessUp" })
        let down = try XCTUnwrap(prefs.first { $0.itemKey == "brightnessDown" })
        XCTAssertFalse(up.isVisible)
        XCTAssertFalse(down.isVisible)
    }

    func testRegularItemsAreSeededVisible() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let prefs = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let brightness = try XCTUnwrap(prefs.first { $0.itemKey == "brightness" })
        let keepAwake = try XCTUnwrap(prefs.first { $0.itemKey == "keepAwake" })
        XCTAssertTrue(brightness.isVisible)
        XCTAssertTrue(keepAwake.isVisible)
    }

    func testSeederIsIdempotent() throws {
        let ctx = try makeInMemoryContext()
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let first = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let second = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).count
        XCTAssertEqual(first, second)
    }
}
```

- [ ] **Step 3.2: Modify the seeder**

In `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` change the `BuiltinPreference(...)` initializer at line 26-32 from:

```swift
                let pref = BuiltinPreference(
                    itemKey: item.rawValue,
                    isVisible: true,
                    displayOrder: order,
                    keyCode: nil,
                    modifierFlags: nil
                )
```

to:

```swift
                let pref = BuiltinPreference(
                    itemKey: item.rawValue,
                    isVisible: item.defaultVisibility,
                    displayOrder: order,
                    keyCode: nil,
                    modifierFlags: nil
                )
```

- [ ] **Step 3.3: Run the seeder tests**

```bash
swift test --filter BuiltinPreferenceSeederTests 2>&1 | tail -20
```

Expected: all 3 tests pass.

- [ ] **Step 3.4: Commit**

```bash
git add Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift Tests/AnyDoorTests/BuiltinPreferenceSeederTests.swift
git commit -m "feat(brightness): seeder honours BuiltinItem.defaultVisibility"
```

---

## Task 4 — Extend `HotkeyAction` enum

**Files:**
- Modify: `Sources/AnyDoor/Models/HotkeyAction.swift`

- [ ] **Step 4.1: Add the two new cases**

Replace the `HotkeyAction` enum body to:

```swift
enum HotkeyAction: Sendable, Hashable {
    case launchApp(bundleID: String, path: String)
    case toggleBuiltin(itemKey: String)
    case runBuiltin(itemKey: String)
    case brightnessUp
    case brightnessDown
}
```

- [ ] **Step 4.2: Verify build (file in isolation)**

```bash
swift build 2>&1 | grep -E "(HotkeyAction|error:)" | head -20
```

Errors about exhaustive switches in `PanelStore.swift:174` are expected; they will be addressed in Task 6. Other errors should not appear.

- [ ] **Step 4.3: Commit**

```bash
git add Sources/AnyDoor/Models/HotkeyAction.swift
git commit -m "feat(brightness): add brightnessUp/Down HotkeyAction cases"
```

---

## Task 5 — Patch every exhaustive switch on `BuiltinItem.Kind`

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelRowView.swift:52-56`
- Modify: `Sources/AnyDoor/Views/PanelRowView.swift:86`
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift:83-87`
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift:95`

- [ ] **Step 5.1: Patch `PanelRowView` onTapGesture switch**

In `Sources/AnyDoor/Views/PanelRowView.swift` the `.onTapGesture` switch (around line 52) becomes:

```swift
            switch entry.kind {
            case .toggle:  onToggle()
            case .submenu: onSubmenu()
            case .action:  onAction()
            case .brightnessControl: break          // click is intentionally a no-op (hover-only UI)
            case .hiddenHotkey: break                // never reaches PanelRowView; defensive only
            }
```

- [ ] **Step 5.2: Patch `PanelRowView` trailing view switch**

Find the `trailing` view's `switch entry.kind` (around line 86). Add at the end of the switch (before its closing brace), inside the `@ViewBuilder` block:

```swift
        case .brightnessControl:
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
        case .hiddenHotkey:
            EmptyView()
```

If the existing switch doesn't have `.toggle`, `.submenu`, `.action` as bare cases (they currently use complex bodies), keep their bodies unchanged and only add the two new cases. Verify by reading lines 86-160 of the file first.

- [ ] **Step 5.3: Patch `PanelSettingsView.typeBadge`**

In `Sources/AnyDoor/Views/PanelSettingsView.swift` the `typeBadge` method (lines 82-88) becomes:

```swift
    private func typeBadge(for entry: PanelEntry) -> String {
        switch entry.kind {
        case .toggle:  return "系统"
        case .action:  return "系统 · 动作"
        case .submenu: return "系统 · 子菜单"
        case .brightnessControl: return "系统 · 亮度"
        case .hiddenHotkey:      return "系统 · 全局动作"
        }
    }
```

- [ ] **Step 5.4: Patch `PanelSettingsView.hotkeyField`**

Replace the `hotkeyField` method (lines 90-103) with:

```swift
    @ViewBuilder
    private func hotkeyField(for entry: PanelEntry) -> some View {
        // Items that do not get a row-level hotkey recorder:
        //   - .submenu: opened by hover (children carry their own hotkeys)
        //   - .brightnessControl: bumps are bound inline below the row
        //   - .hiddenHotkey: never rendered in the settings grid
        if case let .builtin(item) = entry.source,
           item.kind == .submenu || item.kind == .brightnessControl || item.kind == .hiddenHotkey {
            Color.clear.frame(width: 150)
        } else {
            HotkeyRecorder(hotkey: .constant(entry.hotkey)) { newValue in
                handleHotkeyChange(entry: entry, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
        }
    }
```

- [ ] **Step 5.5: Verify full build**

```bash
swift build 2>&1 | tail -30
```

Expected: build succeeds. No more "switch must be exhaustive" or "missing case" errors. (If a different switch on `Kind` somewhere else fires, patch it the same way.)

- [ ] **Step 5.6: Commit**

```bash
git add Sources/AnyDoor/Views/PanelRowView.swift Sources/AnyDoor/Views/PanelSettingsView.swift
git commit -m "feat(brightness): extend Kind exhaustive switches for new cases"
```

---

## Task 6 — Update `PanelStore` for hidden hotkeys + brightness dispatch

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift:49-108` (rebuild)
- Modify: `Sources/AnyDoor/Services/PanelStore.swift:174-185` (dispatch)
- Modify: `Sources/AnyDoor/Services/PanelStore.swift:189-225` (rebuildHotkeySnapshots)
- Modify: `Sources/AnyDoor/Services/PanelStore.swift:320-326` (entryUsingHotkey)

- [ ] **Step 6.1: Filter `.hiddenHotkey` out of `topLevelEntries`**

Inside `rebuild()`, just after the line:

```swift
                guard let item = BuiltinItem(rawValue: pref.itemKey) else { continue }
```

add:

```swift
                if item.kind == .hiddenHotkey { continue }
```

- [ ] **Step 6.2: Extend `entryUsingHotkey`**

Replace the existing method (`entryUsingHotkey` at line 320) with:

```swift
    /// Find which entry currently owns a given hotkey (used for conflict detection).
    ///
    /// Scans visible top-level rows + visible app shortcut children + hidden-hotkey
    /// built-ins (e.g., brightness ±) so all hotkey bindings participate in conflict
    /// detection regardless of whether they render as a panel row.
    func entryUsingHotkey(_ hotkey: HotkeyDescriptor, excluding: PanelEntry.Source? = nil) -> PanelEntry? {
        var pool = topLevelEntries + appShortcutChildren

        if let container = modelContainer {
            let context = container.mainContext
            if let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) {
                for pref in prefs {
                    guard let item = BuiltinItem(rawValue: pref.itemKey),
                          item.kind == .hiddenHotkey,
                          let code = pref.keyCode,
                          let mods = pref.modifierFlags else { continue }
                    let entry = PanelEntry(
                        id: PanelEntry.id(for: .builtin(item)),
                        source: .builtin(item),
                        displayOrder: pref.displayOrder,
                        isVisible: false,
                        hotkey: HotkeyDescriptor(keyCode: code, modifierFlags: mods),
                        title: item.title,
                        subtitle: nil,
                        symbol: item.symbol,
                        kind: .hiddenHotkey,
                        toggleState: nil,
                        permission: .notRequired
                    )
                    pool.append(entry)
                }
            }
        }

        for entry in pool {
            if entry.source == excluding { continue }
            if entry.hotkey == hotkey { return entry }
        }
        return nil
    }
```

- [ ] **Step 6.3: Emit brightness snapshots from `rebuildHotkeySnapshots`**

In `rebuildHotkeySnapshots()` the inner BuiltinPreference loop currently skips `.submenu`. Replace that loop (around line 207-221) with:

```swift
        if let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) {
            for pref in prefs {
                guard let item = BuiltinItem(rawValue: pref.itemKey),
                      let code = pref.keyCode,
                      let mods = pref.modifierFlags else { continue }
                let action: HotkeyAction
                switch item.kind {
                case .toggle:
                    action = .toggleBuiltin(itemKey: item.rawValue)
                case .action:
                    action = .runBuiltin(itemKey: item.rawValue)
                case .submenu, .brightnessControl:
                    continue   // hover-opened items don't bind a top-level hotkey
                case .hiddenHotkey:
                    switch item {
                    case .brightnessUp:   action = .brightnessUp
                    case .brightnessDown: action = .brightnessDown
                    default: continue
                    }
                }
                out.append(HotkeySnapshot(
                    keyCode: code,
                    modifierFlags: mods,
                    action: action
                ))
            }
        }
```

- [ ] **Step 6.4: Extend `dispatch` to route brightness actions**

Replace `dispatch(_:)` (line 174-185) with:

```swift
    /// Handle a matched hotkey. Called on the main thread by HotkeyService.
    func dispatch(_ action: HotkeyAction) {
        switch action {
        case .launchApp(let bundleID, let path):
            AppSwitcher.toggle(bundleID: bundleID, appPath: path)
        case .toggleBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.toggle(item) }
        case .runBuiltin(let key):
            guard let item = BuiltinItem(rawValue: key) else { return }
            Task { await self.run(item) }
        case .brightnessUp:
            DisplayBrightnessService.shared.bump(+1.0 / 16.0, target: .displayUnderMouse)
        case .brightnessDown:
            DisplayBrightnessService.shared.bump(-1.0 / 16.0, target: .displayUnderMouse)
        }
    }
```

- [ ] **Step 6.5: Add a setter for the brightness ± hotkeys**

`setBuiltinHotkey(_:hotkey:)` (line 253) already works for any `BuiltinItem` raw value, including `.brightnessUp` / `.brightnessDown`. No new method required — the settings UI in Task 14 will call `panel.setBuiltinHotkey(.brightnessUp, hotkey: ...)`.

- [ ] **Step 6.6: Verify build (with a stubbed service)**

`DisplayBrightnessService.shared.bump(...)` is not yet defined. Add a temporary stub at the bottom of `PanelStore.swift` (will be replaced when Task 11 lands the real service):

Open `Sources/AnyDoor/Services/PanelStore.swift` and append at end-of-file (BEFORE the final closing brace if any — append after the last closing brace of the class):

```swift
// MARK: - Temporary stub until DisplayBrightnessService lands (Task 11)
// This stub keeps the build green during incremental implementation.
// DELETE THIS BLOCK in Task 11 when the real service is added.
@MainActor
enum DisplayBrightnessService {
    static let shared = Self.self
    enum BumpTarget { case displayUnderMouse }
    static func bump(_ delta: Float, target: BumpTarget) { _ = (delta, target) }
}
```

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 6.7: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(brightness): PanelStore dispatches hidden-hotkey brightness actions"
```

---

## Task 7 — `DDCBackend` protocol + `MockDDCBackend`

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/DDCBackend.swift`

- [ ] **Step 7.1: Create the directory**

```bash
mkdir -p Sources/AnyDoor/Services/Brightness
```

- [ ] **Step 7.2: Write the protocol + mock**

Create `Sources/AnyDoor/Services/Brightness/DDCBackend.swift`:

```swift
import Foundation
import CoreGraphics

/// Abstract DDC/CI transport. Two production implementations exist
/// (`IntelDDCBackend` and `Arm64DDCBackend`), selected per slice via
/// `#if arch(arm64)` in the wiring code. `MockDDCBackend` is used by tests.
protocol DDCBackend: Sendable {
    /// Fast, side-effect-free check: is the I2C / IOAVService transport
    /// reachable for this display? Does NOT issue a VCP read.
    func transportReady(displayID: CGDirectDisplayID) -> Bool

    /// Issue a VCP read. Returns nil on timeout / NACK / unsupported VCP.
    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16?

    /// Issue a VCP write. Throws on I/O failure.
    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws
}

/// In-memory mock for unit tests. Scripted return values + recording of calls.
final class MockDDCBackend: DDCBackend, @unchecked Sendable {
    struct ReadCall: Equatable { let displayID: CGDirectDisplayID; let vcp: UInt8 }
    struct WriteCall: Equatable { let displayID: CGDirectDisplayID; let vcp: UInt8; let value: UInt16 }

    private let lock = NSLock()
    private var _transportSupported: Set<CGDirectDisplayID>
    private var _readResults: [CGDirectDisplayID: UInt16?]
    private var _writeError: Error?
    private(set) var readCalls: [ReadCall] = []
    private(set) var writeCalls: [WriteCall] = []

    init(transportSupported: Set<CGDirectDisplayID> = [],
         readResults: [CGDirectDisplayID: UInt16?] = [:],
         writeError: Error? = nil) {
        self._transportSupported = transportSupported
        self._readResults = readResults
        self._writeError = writeError
    }

    func setReadResult(_ value: UInt16?, for displayID: CGDirectDisplayID) {
        lock.lock(); defer { lock.unlock() }
        _readResults[displayID] = value
    }

    func setWriteError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        _writeError = error
    }

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _transportSupported.contains(displayID)
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        lock.lock()
        readCalls.append(ReadCall(displayID: displayID, vcp: vcp))
        let result = _readResults[displayID] ?? nil
        lock.unlock()
        return result
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        lock.lock()
        writeCalls.append(WriteCall(displayID: displayID, vcp: vcp, value: value))
        let err = _writeError
        lock.unlock()
        if let err { throw err }
    }
}
```

- [ ] **Step 7.3: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 7.4: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/DDCBackend.swift
git commit -m "feat(brightness): add DDCBackend protocol and MockDDCBackend"
```

---

## Task 8 — `Arm64DDCBackend` (clean-room IOAVService)

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/Arm64DDCBackend.swift`

This file is `#if arch(arm64)`-gated. All API surface comes from publicly documented IOKit calls plus three private symbols (`IOAVServiceCreate`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`) accessed via `@_silgen_name`. No MonitorControl GPL code is copied.

- [ ] **Step 8.1: Create the file**

Create `Sources/AnyDoor/Services/Brightness/Arm64DDCBackend.swift`:

```swift
#if arch(arm64)
import Foundation
import IOKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "ddc.arm64")

// MARK: - Private IOAVService symbol declarations
//
// These three symbols live in CoreDisplay/IOKit's private surface. Function
// signatures are not copyrightable; the calling convention is documented in
// public Apple sample code (AVCustomEdit, AVScreenShack) and in Apple's
// open-source IOAVService headers shipped historically with xnu.

@_silgen_name("IOAVServiceCreate")
private func IOAVServiceCreate(_ allocator: CFAllocator?) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceCreateWithService")
private func IOAVServiceCreateWithService(
    _ allocator: CFAllocator?,
    _ service: io_service_t
) -> Unmanaged<AnyObject>?

@_silgen_name("IOAVServiceReadI2C")
private func IOAVServiceReadI2C(
    _ service: AnyObject,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ buffer: UnsafeMutableRawPointer,
    _ length: UInt32
) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
private func IOAVServiceWriteI2C(
    _ service: AnyObject,
    _ chipAddress: UInt32,
    _ offset: UInt32,
    _ buffer: UnsafeRawPointer,
    _ length: UInt32
) -> IOReturn

// MARK: - Backend

struct Arm64DDCBackend: DDCBackend {
    /// Per-process cache: displayID -> IOAVService object. Invalidated by
    /// the caller (DisplayBrightnessService) on screen-change notifications.
    private static let cache = AVServiceCache()

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        return Self.cache.service(for: displayID) != nil
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        guard let service = Self.cache.service(for: displayID) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> UInt16? in
            // DDC read request packet: [src=0x51, len=0x82, op=0x01, vcp, chksum]
            // followed by a separate read of the 11-byte reply.
            var request: [UInt8] = [0x51, 0x82, 0x01, vcp]
            request.append(checksum(destination: 0x6E, bytes: request))

            let writeResult = request.withUnsafeBufferPointer { buf -> IOReturn in
                IOAVServiceWriteI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard writeResult == KERN_SUCCESS else { return nil }

            // Per DDC/CI: the source must wait at least 40 ms before reading the reply.
            try? await Task.sleep(nanoseconds: 50_000_000)

            var reply = [UInt8](repeating: 0, count: 11)
            let readResult = reply.withUnsafeMutableBufferPointer { buf -> IOReturn in
                IOAVServiceReadI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard readResult == KERN_SUCCESS, reply[0] == 0x6E, reply[1] == 0x88,
                  reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else {
                return nil
            }
            let current = (UInt16(reply[8]) << 8) | UInt16(reply[9])
            return current
        }.value
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        guard let service = Self.cache.service(for: displayID) else {
            throw NSError(domain: "Arm64DDC", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "transport not ready"])
        }
        try await Task.detached(priority: .userInitiated) {
            // DDC write packet: [src=0x51, len=0x84, op=0x03, vcp, valHi, valLo, chksum]
            var packet: [UInt8] = [0x51, 0x84, 0x03, vcp,
                                   UInt8((value >> 8) & 0xFF),
                                   UInt8(value & 0xFF)]
            packet.append(checksum(destination: 0x6E, bytes: packet))

            let result = packet.withUnsafeBufferPointer { buf -> IOReturn in
                IOAVServiceWriteI2C(service, 0x37, 0x51, buf.baseAddress!, UInt32(buf.count))
            }
            guard result == KERN_SUCCESS else {
                throw NSError(domain: "Arm64DDC", code: Int(result),
                              userInfo: [NSLocalizedDescriptionKey: "I2C write failed"])
            }
        }.value
    }
}

private func checksum(destination: UInt8, bytes: [UInt8]) -> UInt8 {
    var sum = destination
    for byte in bytes { sum ^= byte }
    return sum
}

/// Per-displayID IOAVService lookup, cached for the process lifetime.
/// Higher layers must drop entries on screen-change notifications.
private final class AVServiceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [CGDirectDisplayID: AnyObject] = [:]

    func service(for displayID: CGDirectDisplayID) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        if let s = map[displayID] { return s }
        guard let s = locateService(for: displayID) else { return nil }
        map[displayID] = s
        return s
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
    }

    /// Walks IORegistry for IOAVService entries; matches by the IOAVService's
    /// "VendorID" / "ProductID" / "AlphanumericSerialNumber" against
    /// `CGDisplayVendorNumber` / `CGDisplayModelNumber` / `CGDisplaySerialNumber`.
    private func locateService(for displayID: CGDirectDisplayID) -> AnyObject? {
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        guard vendor != 0 || model != 0 else { return nil }

        var iter: io_iterator_t = 0
        let matching = IOServiceMatching("IOAVService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iter) }

        var match: AnyObject?
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }
            guard let props = serviceProperties(service) else { continue }
            let v = (props["VendorID"] as? UInt32) ?? 0
            let m = (props["ProductID"] as? UInt32) ?? 0
            let s = (props["AlphanumericSerialNumber"] as? String).flatMap(UInt32.init) ?? 0
            if v == vendor && m == model && (serial == 0 || s == serial) {
                if let av = IOAVServiceCreateWithService(kCFAllocatorDefault, service)?.takeRetainedValue() {
                    match = av
                    break
                }
            }
        }
        return match
    }

    private func serviceProperties(_ service: io_service_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS, let dict = unmanaged?.takeRetainedValue() else { return nil }
        return dict as? [String: Any]
    }
}

#endif
```

- [ ] **Step 8.2: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds on this Apple Silicon machine. The file is unused so far.

- [ ] **Step 8.3: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/Arm64DDCBackend.swift
git commit -m "feat(brightness): clean-room Arm64DDCBackend via IOAVService"
```

> **Note for QA:** matching displays to `IOAVService` entries is approximation-based; some monitors expose `VendorID` 0 or share `ProductID`. If a real-world display fails to match, fall back to walking by display index. Defer this hardening until QA flags a specific monitor.

---

## Task 9 — `IntelDDCBackend` (wraps DDC.swift)

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/IntelDDCBackend.swift`

- [ ] **Step 9.1: Create the file**

Create `Sources/AnyDoor/Services/Brightness/IntelDDCBackend.swift`:

```swift
#if !arch(arm64)
import Foundation
import CoreGraphics
import DDC

struct IntelDDCBackend: DDCBackend {
    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        return DDC(for: displayID) != nil
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        await Task.detached(priority: .userInitiated) {
            guard let ddc = DDC(for: displayID) else { return UInt16?.none }
            guard let result = ddc.read(command: DDC.Command(rawValue: vcp) ?? .brightness) else {
                return nil
            }
            return UInt16(result.current)
        }.value
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard let ddc = DDC(for: displayID) else {
                throw NSError(domain: "IntelDDC", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "DDC unavailable"])
            }
            let ok = ddc.write(command: DDC.Command(rawValue: vcp) ?? .brightness,
                                value: value)
            if !ok {
                throw NSError(domain: "IntelDDC", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "DDC write failed"])
            }
        }.value
    }
}
#endif
```

> **API note:** If the actual DDC.swift API differs from `DDC(for:)` / `.read(command:)` / `.write(command:value:)`, adjust to match. Look at `swift package describe` or open `~/.swiftpm/...` checkout for the real signatures. The wrapper boundary is small so updates are localized.

- [ ] **Step 9.2: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds (file is wrapped in `#if !arch(arm64)` so on Apple Silicon it is empty; the SPM dependency still resolves).

- [ ] **Step 9.3: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/IntelDDCBackend.swift
git commit -m "feat(brightness): IntelDDCBackend wrapping DDC.swift"
```

---

## Task 10 — `BrightnessController` actor

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/BrightnessController.swift`
- Create: `Tests/AnyDoorTests/BrightnessControllerTests.swift`

- [ ] **Step 10.1: Write the failing tests**

Create `Tests/AnyDoorTests/BrightnessControllerTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

final class BrightnessControllerTests: XCTestCase {
    func testProbeReturnsTrueWhenTransportReady() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let result = await controller.probe(displayID: displayID)
        XCTAssertTrue(result)
    }

    func testProbeReturnsFalseWhenTransportMissing() async {
        let backend = MockDDCBackend(transportSupported: [])
        let controller = BrightnessController(backend: backend)
        let result = await controller.probe(displayID: 1)
        XCTAssertFalse(result)
    }

    func testReadNormalizesToZeroOne() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: 50])
        let controller = BrightnessController(backend: backend)
        let value = await controller.read(displayID: displayID)
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, 0.5, accuracy: 0.01)
    }

    func testReadReturnsNilOnBackendNil() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: nil])
        let controller = BrightnessController(backend: backend)
        let value = await controller.read(displayID: displayID)
        XCTAssertNil(value)
    }

    func testWriteRetriesOnceOnFailure() async {
        let displayID: CGDirectDisplayID = 1
        let backend = FlakyBackend(failuresBeforeSuccess: 1, supports: [displayID])
        let controller = BrightnessController(backend: backend)
        try? await controller.write(displayID: displayID, value: 0.75)
        XCTAssertEqual(backend.writeCount, 2)
    }

    func testWriteThrowsAfterTwoFailures() async {
        let displayID: CGDirectDisplayID = 1
        let backend = FlakyBackend(failuresBeforeSuccess: .max, supports: [displayID])
        let controller = BrightnessController(backend: backend)
        do {
            try await controller.write(displayID: displayID, value: 0.5)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(backend.writeCount, 2)
        }
    }
}

private final class FlakyBackend: DDCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let _supports: Set<CGDirectDisplayID>
    private(set) var writeCount = 0

    init(failuresBeforeSuccess: Int, supports: Set<CGDirectDisplayID>) {
        self.remainingFailures = failuresBeforeSuccess
        self._supports = supports
    }

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        _supports.contains(displayID)
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? { nil }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        lock.lock()
        writeCount += 1
        let shouldFail = remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        if shouldFail {
            throw NSError(domain: "flaky", code: 1)
        }
    }
}
```

- [ ] **Step 10.2: Run tests; verify they fail**

```bash
swift test --filter BrightnessControllerTests 2>&1 | tail -10
```

Expected: compile errors ("cannot find 'BrightnessController' in scope").

- [ ] **Step 10.3: Implement `BrightnessController`**

Create `Sources/AnyDoor/Services/Brightness/BrightnessController.swift`:

```swift
import Foundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "brightness.controller")

/// Serialises VCP 0x10 I/O for one or more displays. One write retry on failure.
/// Read/write timeouts handled by the underlying backend.
///
/// Always operates on VCP 0x10 (brightness). Values are normalised to 0.0...1.0
/// on the public API; internally converted to the DDC byte range 0...100.
actor BrightnessController {
    enum Failure: Error { case transportUnavailable, writeFailed }

    private let backend: DDCBackend
    private static let vcpBrightness: UInt8 = 0x10
    /// DDC standard: brightness max value byte for VCP 0x10 on essentially every
    /// monitor. A VCP-max handshake is deferred (see spec § "Out-of-scope failure modes").
    private static let maxValue: UInt16 = 100

    init(backend: DDCBackend) {
        self.backend = backend
    }

    /// Transport probe — fast, no VCP query. Returns true iff the backend reports
    /// the display reachable. A subsequent read or write may still time out.
    func probe(displayID: CGDirectDisplayID) async -> Bool {
        return backend.transportReady(displayID: displayID)
    }

    /// Reads current brightness, normalised 0.0...1.0; nil on backend nil.
    func read(displayID: CGDirectDisplayID) async -> Float? {
        guard let raw = await backend.read(displayID: displayID, vcp: Self.vcpBrightness) else {
            return nil
        }
        return Float(min(raw, Self.maxValue)) / Float(Self.maxValue)
    }

    /// Writes brightness (0.0...1.0). Throws `Failure.writeFailed` after exactly
    /// one retry on transient failure.
    func write(displayID: CGDirectDisplayID, value: Float) async throws {
        let clamped = max(0, min(1, value))
        let raw = UInt16((clamped * Float(Self.maxValue)).rounded())
        do {
            try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
        } catch {
            logger.debug("DDC write retry for display \(displayID, privacy: .public)")
            do {
                try await backend.write(displayID: displayID, vcp: Self.vcpBrightness, value: raw)
            } catch {
                throw Failure.writeFailed
            }
        }
    }
}
```

- [ ] **Step 10.4: Run tests**

```bash
swift test --filter BrightnessControllerTests 2>&1 | tail -15
```

Expected: all 6 tests pass.

- [ ] **Step 10.5: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/BrightnessController.swift Tests/AnyDoorTests/BrightnessControllerTests.swift
git commit -m "feat(brightness): BrightnessController actor with retry semantics"
```

---

## Task 11 — `DisplayBrightnessService` (replaces the stub from Task 6)

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/DisplayBrightnessService.swift`
- Create: `Tests/AnyDoorTests/DisplayBrightnessServiceTests.swift`
- Modify: `Sources/AnyDoor/Services/PanelStore.swift` (remove Task 6 stub)

- [ ] **Step 11.1: Write the failing tests**

Create `Tests/AnyDoorTests/DisplayBrightnessServiceTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

@MainActor
final class DisplayBrightnessServiceTests: XCTestCase {
    func testSetBrightnessUpdatesLevelsImmediately() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setBrightness(0.42, for: displayID)
        XCTAssertEqual(service.levels[displayID], 0.42)
    }

    func testSetBrightnessDebouncesWrites() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setBrightness(0.1, for: displayID)
        service.setBrightness(0.2, for: displayID)
        service.setBrightness(0.3, for: displayID)
        // wait for debounce window (30 ms) + execution slack
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(backend.writeCalls.count, 1, "expected one consolidated write")
        XCTAssertEqual(backend.writeCalls.last?.value, 30) // 0.3 * 100
    }

    func testBumpUsesFallbackBaselineWhenNil() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        // levels[displayID] starts nil → bump uses 0.5 + 0.0625 = 0.5625
        service.bumpForTesting(+0.0625, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 0.5625, accuracy: 0.001)
    }

    func testBumpClampsToZeroOne() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setLevelForTesting(0.95, for: displayID)
        service.bumpForTesting(+0.5, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 1.0, accuracy: 0.001)

        service.setLevelForTesting(0.05, for: displayID)
        service.bumpForTesting(-0.5, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 0.0, accuracy: 0.001)
    }

    func testGenerationTokenInvalidatesBackfill() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: 80])  // real device value
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        // levels[id] nil → triggers backfill after write
        service.bumpForTesting(+0.0625, displayID: displayID)
        let immediate = service.levels[displayID]
        XCTAssertEqual(immediate!, 0.5625, accuracy: 0.001)

        // Before backfill completes, user nudges again → generation bumps,
        // backfill must not clobber.
        service.bumpForTesting(+0.0625, displayID: displayID)
        let post = service.levels[displayID]
        XCTAssertEqual(post!, 0.625, accuracy: 0.001)

        // Give the backfill ample time to (incorrectly) overwrite.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Generation guard wins → still 0.625, NOT 0.8 (backfill discarded).
        XCTAssertEqual(service.levels[displayID]!, 0.625, accuracy: 0.001)
    }
}
```

- [ ] **Step 11.2: Run tests; verify they fail**

```bash
swift test --filter DisplayBrightnessServiceTests 2>&1 | tail -15
```

Expected: compile errors.

- [ ] **Step 11.3: Remove the Task 6 stub from PanelStore.swift**

Delete the block at the bottom of `Sources/AnyDoor/Services/PanelStore.swift` that begins with `// MARK: - Temporary stub until DisplayBrightnessService lands (Task 11)`.

- [ ] **Step 11.4: Implement the service**

Create `Sources/AnyDoor/Services/Brightness/DisplayBrightnessService.swift`:

```swift
import Foundation
import AppKit
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "brightness.service")

struct DisplayInfo: Identifiable, Hashable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let supportsDDC: Bool
}

@MainActor
@Observable
final class DisplayBrightnessService {
    static let shared = DisplayBrightnessService()

    private(set) var displays: [DisplayInfo] = []
    private(set) var levels: [CGDirectDisplayID: Float] = [:]
    private(set) var isLoading: Set<CGDirectDisplayID> = []

    /// Monotonic counter per display, incremented on every level mutation.
    /// Used by deferred backfill reads to drop themselves when a newer user
    /// action has superseded them.
    private var levelGeneration: [CGDirectDisplayID: UInt64] = [:]

    private var controller: BrightnessController?
    private var screenChangeObserver: NSObjectProtocol?
    private var pendingWrites: [CGDirectDisplayID: Task<Void, Never>] = [:]
    private static let writeDebounceNanos: UInt64 = 30_000_000   // 30 ms

    enum BumpTarget: Sendable { case displayUnderMouse }

    init() {}

    func bootstrap(controller: BrightnessController) {
        self.controller = controller
        installScreenObserver()
    }

    private func installScreenObserver() {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    /// Re-enumerate NSScreen.screens; probe + read every external display.
    func refresh() async {
        guard let controller else { return }

        let externalIDs = Self.externalDisplayIDs()
        var newDisplays: [DisplayInfo] = []
        var rawNames: [(CGDirectDisplayID, String)] = []

        for id in externalIDs {
            let baseName = Self.localizedName(for: id) ?? "Display \(id)"
            rawNames.append((id, baseName))
        }

        let dedupedNames = Self.dedupedNames(rawNames)

        for (id, name) in zip(externalIDs, dedupedNames) {
            isLoading.insert(id)
            let supports = await controller.probe(displayID: id)
            newDisplays.append(DisplayInfo(id: id, name: name, supportsDDC: supports))
            if supports {
                if let value = await controller.read(displayID: id) {
                    levels[id] = value
                }
            }
            isLoading.remove(id)
        }

        // Drop entries for unplugged displays.
        let present = Set(newDisplays.map(\.id))
        for stale in levels.keys where !present.contains(stale) { levels.removeValue(forKey: stale) }

        displays = newDisplays
    }

    /// Slider drag entry. Updates UI immediately; debounces DDC write.
    func setBrightness(_ value: Float, for displayID: CGDirectDisplayID) {
        guard let controller else { return }
        let clamped = max(0, min(1, value))
        levels[displayID] = clamped
        bumpGeneration(displayID)
        pendingWrites[displayID]?.cancel()
        pendingWrites[displayID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.writeDebounceNanos)
            if Task.isCancelled { return }
            try? await controller.write(displayID: displayID, value: clamped)
            await MainActor.run { [weak self] in
                self?.pendingWrites[displayID] = nil
            }
        }
    }

    /// Hotkey bump entry.
    func bump(_ delta: Float, target: BumpTarget) {
        guard let displayID = resolveTarget(target) else { return }
        bumpInternal(delta, displayID: displayID, showOSD: true)
    }

    // MARK: - Internal (also reused by test seams)

    fileprivate func bumpInternal(_ delta: Float, displayID: CGDirectDisplayID, showOSD: Bool) {
        guard let controller else { return }
        let usedFallback = (levels[displayID] == nil)
        let baseline = levels[displayID] ?? 0.5
        let newValue = max(0, min(1, baseline + delta))
        bumpGeneration(displayID)
        let gen = levelGeneration[displayID] ?? 0
        levels[displayID] = newValue

        if showOSD {
            OSDBridge.showBrightness(newValue, on: displayID)
        }

        // Task started from a @MainActor method in Swift 6 inherits MainActor
        // isolation. The actor `await controller.write/read` hops away and back
        // automatically, so direct `self.levelGeneration[...]` checks are
        // MainActor-safe without explicit MainActor.run wrappers.
        Task { [weak self] in
            do {
                try await controller.write(displayID: displayID, value: newValue)
            } catch {
                return
            }
            guard let self else { return }
            guard usedFallback else { return }
            guard self.levelGeneration[displayID] == gen else { return }
            guard let real = await controller.read(displayID: displayID) else { return }
            guard self.levelGeneration[displayID] == gen else { return }
            self.levels[displayID] = real
        }
    }

    private func bumpGeneration(_ id: CGDirectDisplayID) {
        levelGeneration[id, default: 0] &+= 1
    }

    private func resolveTarget(_ target: BumpTarget) -> CGDirectDisplayID? {
        switch target {
        case .displayUnderMouse:
            return Self.displayUnderMouse(displays: displays) ?? Self.mainDisplayIfSupported(displays: displays)
        }
    }

    // MARK: - Static helpers (pure functions, no MainActor state)

    private static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.filter { CGDisplayIsBuiltin($0) == 0 }
    }

    private static func localizedName(for displayID: CGDirectDisplayID) -> String? {
        // CoreDisplay_DisplayCreateInfoDictionary is private; the lazy path is
        // NSScreen's localizedName from macOS 11+. Match the display via
        // NSScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber,
               number.uint32Value == displayID {
                return screen.localizedName
            }
        }
        return nil
    }

    fileprivate static func dedupedNames(_ pairs: [(CGDirectDisplayID, String)]) -> [String] {
        var counts: [String: Int] = [:]
        // Stable: first occurrence keeps the bare name, subsequent get " (n)".
        let sorted = pairs.sorted { $0.0 < $1.0 }
        var result = Array(repeating: "", count: pairs.count)
        var assigned: [CGDirectDisplayID: String] = [:]
        for (id, name) in sorted {
            let n = counts[name] ?? 0
            assigned[id] = (n == 0) ? name : "\(name) (\(n))"
            counts[name] = n + 1
        }
        for (i, pair) in pairs.enumerated() { result[i] = assigned[pair.0] ?? pair.1 }
        return result
    }

    private static func displayUnderMouse(displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber {
                let id = number.uint32Value
                if displays.contains(where: { $0.id == id && $0.supportsDDC }) { return id }
            }
        }
        return nil
    }

    private static func mainDisplayIfSupported(displays: [DisplayInfo]) -> CGDirectDisplayID? {
        let id = CGMainDisplayID()
        return displays.contains(where: { $0.id == id && $0.supportsDDC }) ? id : nil
    }
}

// MARK: - Test seams (XCTest @testable import)

extension DisplayBrightnessService {
    func injectDisplaysForTesting(_ d: [DisplayInfo]) { self.displays = d }
    func setLevelForTesting(_ v: Float, for id: CGDirectDisplayID) { levels[id] = v }
    func bumpForTesting(_ delta: Float, displayID: CGDirectDisplayID) {
        bumpInternal(delta, displayID: displayID, showOSD: false)
    }
}
```

- [ ] **Step 11.5: Run tests**

```bash
swift test --filter DisplayBrightnessServiceTests 2>&1 | tail -15
```

Expected: all 5 tests pass. `swift build` also passes.

- [ ] **Step 11.6: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/DisplayBrightnessService.swift \
        Tests/AnyDoorTests/DisplayBrightnessServiceTests.swift \
        Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(brightness): DisplayBrightnessService with debounce + generation token"
```

---

## Task 12 — `OSDBridge`

**Files:**
- Create: `Sources/AnyDoor/Services/Brightness/OSDBridge.swift`

- [ ] **Step 12.1: Implement the bridge**

Create `Sources/AnyDoor/Services/Brightness/OSDBridge.swift`:

```swift
import Foundation
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "osd.bridge")

/// Triggers macOS's native chiclet brightness OSD via the private
/// `OSDManager.sharedManager()` API resident in `OSD.framework`.
/// Best-effort; silent no-op on any failure path. Brightness still
/// takes effect at the display via DDC regardless.
enum OSDBridge {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/OSD.framework/OSD"
    private static let brightnessImageID: Int64 = 1   // OSDGraphic.brightness
    private static let totalChiclets: UInt32 = 16
    private static let msecUntilFade: UInt32 = 1500
    private static let priority: UInt32 = 0x0

    private static let loadedHandle: UnsafeMutableRawPointer? = {
        dlopen(frameworkPath, RTLD_LAZY)
    }()

    static func showBrightness(_ value: Float, on displayID: CGDirectDisplayID) {
        guard loadedHandle != nil else {
            logger.debug("OSD.framework not loaded; skipping OSD")
            return
        }
        guard let managerClass = NSClassFromString("OSDManager") as? NSObject.Type else {
            logger.debug("OSDManager class not found; skipping OSD")
            return
        }
        let manager = managerClass.perform(NSSelectorFromString("sharedManager"))?
            .takeUnretainedValue()
        guard let manager = manager as? NSObject else {
            logger.debug("OSDManager.sharedManager returned nil; skipping OSD")
            return
        }
        let selector = NSSelectorFromString(
            "showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:"
        )
        guard manager.responds(to: selector) else {
            logger.debug("OSDManager does not respond to chiclet selector; skipping OSD")
            return
        }
        let filled = UInt32((max(0, min(1, value)) * Float(totalChiclets)).rounded())

        // Build an Obj-C invocation with the exact method signature so we can
        // pass primitive (non-object) arguments.
        let signature: NSMethodSignature? = manager.method(for: selector).flatMap { _ in
            (manager as AnyObject).methodSignature(for: selector)
        }
        guard let signature else {
            logger.debug("OSDManager method signature missing; skipping OSD")
            return
        }
        let invocation = NSInvocation.invocation(with: signature)
        invocation.target = manager
        invocation.selector = selector
        var image: Int64 = brightnessImageID
        var did: UInt32 = displayID
        var prio: UInt32 = priority
        var fade: UInt32 = msecUntilFade
        var f: UInt32 = filled
        var t: UInt32 = totalChiclets
        var locked: ObjCBool = false
        invocation.setArgument(&image, at: 2)
        invocation.setArgument(&did, at: 3)
        invocation.setArgument(&prio, at: 4)
        invocation.setArgument(&fade, at: 5)
        invocation.setArgument(&f, at: 6)
        invocation.setArgument(&t, at: 7)
        invocation.setArgument(&locked, at: 8)
        invocation.invoke()
    }
}

// MARK: - NSInvocation Swift-friendly bridge

private extension NSObject {
    @objc func methodSignature(for selector: Selector) -> NSMethodSignature? {
        let cls: AnyClass = type(of: self)
        return cls.instanceMethodSignature(for: selector)
    }
}

private extension AnyClass {
    static func instanceMethodSignature(for selector: Selector) -> NSMethodSignature? {
        // NSObject conforms; method_getTypeEncoding on the IMP yields the signature.
        guard let method = class_getInstanceMethod(self, selector),
              let encoding = method_getTypeEncoding(method) else { return nil }
        return NSMethodSignature.signature(withObjCTypes: encoding)
    }
}

private extension NSMethodSignature {
    static func signature(withObjCTypes encoding: UnsafePointer<CChar>) -> NSMethodSignature? {
        // The +signatureWithObjCTypes: selector is non-public to Swift; access via
        // performSelector on the metatype.
        let sel = NSSelectorFromString("signatureWithObjCTypes:")
        guard let meta = NSMethodSignature.self as AnyObject as? NSObjectProtocol,
              meta.responds(to: sel) else { return nil }
        let unmanaged = meta.perform(sel, with: encoding)
        return unmanaged?.takeUnretainedValue() as? NSMethodSignature
    }
}

private extension NSInvocation {
    static func invocation(with signature: NSMethodSignature) -> NSInvocation {
        let sel = NSSelectorFromString("invocationWithMethodSignature:")
        let cls: AnyClass = NSInvocation.self as AnyClass
        let meta: AnyObject = cls
        return (meta as AnyObject).perform(sel, with: signature)!
            .takeUnretainedValue() as! NSInvocation
    }
}
```

> **Note on Swift+NSInvocation:** Swift does not expose `NSInvocation` directly, but the runtime is reachable via `NSSelectorFromString` + `perform`. The boilerplate above is one-time and isolated to this file. If a future macOS removes any of these private classes / selectors, the failure mode is silent no-op (graceful degradation).

- [ ] **Step 12.2: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 12.3: Commit**

```bash
git add Sources/AnyDoor/Services/Brightness/OSDBridge.swift
git commit -m "feat(brightness): OSDBridge wrapping private OSD.framework"
```

---

## Task 13 — `BrightnessPopoverView` + `DisplayBrightnessCard`

**Files:**
- Create: `Sources/AnyDoor/Views/BrightnessPopoverView.swift`

- [ ] **Step 13.1: Implement the views**

Create `Sources/AnyDoor/Views/BrightnessPopoverView.swift`:

```swift
import SwiftUI
import CoreGraphics

struct BrightnessPopoverView: View {
    @State private var service = DisplayBrightnessService.shared
    var onHoverChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if service.displays.isEmpty {
                emptyState(text: "未检测到外置显示器", symbol: "display")
            } else if service.displays.allSatisfy({ !$0.supportsDDC }) {
                VStack(alignment: .leading, spacing: 4) {
                    emptyState(text: "未检测到支持 DDC 的外置显示器", symbol: "display.slash")
                    Text("DisplayPort/HDMI 通常可用，部分 USB-C 转接线不支持")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                ForEach(service.displays) { info in
                    DisplayBrightnessCard(info: info, service: service)
                }
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .onAppear {
            Task { await service.refresh() }
        }
        .onHover { onHoverChange($0) }
    }

    private func emptyState(text: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

private struct DisplayBrightnessCard: View {
    let info: DisplayInfo
    @Bindable var service: DisplayBrightnessService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(info.name).font(.headline)
                if !info.supportsDDC {
                    Text("不支持 DDC")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if service.isLoading.contains(info.id) {
                    ProgressView().controlSize(.mini)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.max.fill").foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(service.levels[info.id] ?? 0.5) },
                        set: { service.setBrightness(Float($0), for: info.id) }
                    ),
                    in: 0...1
                )
                .controlSize(.large)
                .disabled(!info.supportsDDC)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .opacity(info.supportsDDC ? 1.0 : 0.55)
    }
}
```

- [ ] **Step 13.2: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 13.3: Commit**

```bash
git add Sources/AnyDoor/Views/BrightnessPopoverView.swift
git commit -m "feat(brightness): BrightnessPopoverView and DisplayBrightnessCard"
```

---

## Task 14 — Wire the popover into `MenuBarView`

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift:10-13` (HoverPopoverTarget)
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift:115-172` (rowView)
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift:215-290` (mountPopoverContent)

- [ ] **Step 14.1: Extend `HoverPopoverTarget`**

Replace the enum at lines 10-13 with:

```swift
private enum HoverPopoverTarget: Hashable {
    case submenu(BuiltinItem)
    case history(ClipboardHistoryKind)
    case brightnessControl(BuiltinItem)
}
```

- [ ] **Step 14.2: Register the trigger in `rowView`**

In the `rowView(for:)` function, locate the existing `if case let .builtin(item) = entry.source, item.kind == .submenu` branch (around line 117). After its closing brace and BEFORE the `} else if case let .builtin(item) = entry.source, item.kind == .action, ...` branch, add a new branch:

```swift
        } else if case let .builtin(item) = entry.source, item.kind == .brightnessControl {
            let target = HoverPopoverTarget.brightnessControl(item)
            PanelRowView(
                entry: entry,
                onToggle: {},
                onAction: {},
                onSubmenu: {},
                onPermission: openPermissionsSettings
            )
            .background(
                ScreenFrameReader { frame in
                    triggerFrames[target] = frame
                }
            )
            .onHover { hovered in
                triggerHover(hovered, target: target)
            }
```

- [ ] **Step 14.3: Add the `mountPopoverContent` branch**

Inside `mountPopoverContent(for:)` (around line 215), add a new case **before** the `case .submenu:` fallthrough comment-case (line 256):

```swift
        case .brightnessControl:
            popover.needsKeyFocus = false
            popover.updateContent {
                BrightnessPopoverView(onHoverChange: { gate.popoverHover($0) })
            }
            popover.show(anchoredTo: convertedTriggerFrame(for: target))
```

- [ ] **Step 14.4: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 14.5: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(brightness): wire brightness popover into MenuBarView hover routing"
```

---

## Task 15 — Inline ± hotkey recorder under the brightness row in Panel Settings

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift` (add `hotkeyForBuiltin` helper)
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift:46-56` (row builder)

- [ ] **Step 15.1: Add `hotkeyForBuiltin` to `PanelStore`**

In `Sources/AnyDoor/Services/PanelStore.swift`, add a public helper near the other public helpers (after `binding(id:)` at line 233):

```swift
    /// Look up the current hotkey assigned to a built-in item, if any.
    /// Reads from SwiftData rather than `topLevelEntries` so it works for
    /// hidden-hotkey items (e.g., brightness ±).
    func hotkeyForBuiltin(_ item: BuiltinItem) -> HotkeyDescriptor? {
        guard let container = modelContainer else { return nil }
        let key = item.rawValue
        guard let pref = try? container.mainContext.fetch(
            FetchDescriptor<BuiltinPreference>(predicate: #Predicate { $0.itemKey == key })
        ).first,
        let code = pref.keyCode, let mods = pref.modifierFlags else { return nil }
        return HotkeyDescriptor(keyCode: code, modifierFlags: mods)
    }
```

Build verification:

```bash
swift build 2>&1 | tail -10
```

Expected: succeeds.

- [ ] **Step 15.2: Add the inline expansion to `PanelSettingsView`**

Replace the `row(for:)` method (lines 46-56) with:

```swift
    @ViewBuilder
    private func row(for entry: PanelEntry) -> some View {
        VStack(spacing: 0) {
            mainRow(entry)
            if case .builtin(.appShortcuts) = entry.source {
                appShortcutChildren()
                addAppButton()
            }
            if case .builtin(.brightness) = entry.source {
                brightnessHotkeyRecorders()
            }
        }
        .opacity(entry.isVisible ? 1.0 : 0.5)
    }

    @ViewBuilder
    private func brightnessHotkeyRecorders() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            brightnessHotkeyRow(item: .brightnessUp, label: "亮度 +")
            brightnessHotkeyRow(item: .brightnessDown, label: "亮度 −")
        }
        .padding(.leading, 36)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func brightnessHotkeyRow(item: BuiltinItem, label: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            HotkeyRecorder(hotkey: .constant(PanelStore.shared.hotkeyForBuiltin(item))) { newValue in
                handleBrightnessHotkeyChange(item: item, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
        }
    }

    private func handleBrightnessHotkeyChange(item: BuiltinItem, newValue: HotkeyDescriptor?) {
        if let new = newValue,
           let existing = PanelStore.shared.entryUsingHotkey(new, excluding: .builtin(item)) {
            conflictAlert = ConflictAlert(
                hotkey: new,
                existingTitle: existing.title,
                onReplace: {
                    if case let .builtin(other) = existing.source {
                        PanelStore.shared.setBuiltinHotkey(other, hotkey: nil)
                    } else if case let .appShortcut(id) = existing.source {
                        PanelStore.shared.updateAppShortcut(id: id, hotkey: nil)
                    }
                    PanelStore.shared.setBuiltinHotkey(item, hotkey: new)
                }
            )
        } else {
            PanelStore.shared.setBuiltinHotkey(item, hotkey: newValue)
        }
    }
```

Build verification:

```bash
swift build 2>&1 | tail -10
```

Expected: succeeds.

- [ ] **Step 15.3: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsView.swift Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(brightness): inline brightness +/- hotkey recorders in panel settings"
```

---

## Task 16 — Bootstrap from `AppDelegate`

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift:75-101`

- [ ] **Step 16.1: Build and bootstrap the service before HotkeyService.start()**

In `Sources/AnyDoor/AppDelegate.swift`, after the line `PanelStore.shared.bootstrap(modelContainer: modelContainer, providers: providers)` (line 75) add:

```swift
        // Brightness control (external DDC/CI displays). Arch-selected backend.
        #if arch(arm64)
        let ddcBackend: any DDCBackend = Arm64DDCBackend()
        #else
        let ddcBackend: any DDCBackend = IntelDDCBackend()
        #endif
        let brightnessController = BrightnessController(backend: ddcBackend)
        DisplayBrightnessService.shared.bootstrap(controller: brightnessController)

        // Pre-warm the brightness service so the first hover finds data cached.
        Task.detached(priority: .utility) {
            await DisplayBrightnessService.shared.refresh()
        }
```

- [ ] **Step 16.2: Build verification**

```bash
swift build 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 16.3: Smoke run**

```bash
swift run 2>&1 | head -30 &
RUNPID=$!
sleep 5
kill $RUNPID 2>/dev/null
wait 2>/dev/null
```

Expected: app starts, no crash in the first 5 seconds. The menu-bar item appears in the system menu bar (visible during the 5s window). Hover over "屏幕亮度" to verify the popover renders. Manual verification only — automate nothing here.

- [ ] **Step 16.4: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(brightness): bootstrap DisplayBrightnessService and pre-warm refresh"
```

---

## Task 17 — README attribution

**Files:**
- Modify: `README.md`
- Modify: `README.zh-CN.md`

- [ ] **Step 17.1: Find the right section**

Both README files likely have an "Acknowledgements" / "致谢" / "Built with" section. If not, create one at the end:

In `README.md` (English):

```markdown
## Acknowledgements

- [DDC.swift](https://github.com/reitermarkus/DDC.swift) (MIT) — DDC/CI
  brightness control for external displays on Intel Macs.
- [AskForPermission](https://github.com/riko2chen/AskForPermission) — macOS
  accessibility permission helper.
- [Sparkle](https://sparkle-project.org/) — application auto-update.
```

In `README.zh-CN.md` (Chinese):

```markdown
## 致谢

- [DDC.swift](https://github.com/reitermarkus/DDC.swift) (MIT) — Intel Mac
  上外置显示器的 DDC/CI 亮度控制。
- [AskForPermission](https://github.com/riko2chen/AskForPermission) — macOS
  辅助功能权限助手。
- [Sparkle](https://sparkle-project.org/) — 应用自动更新。
```

If a section already exists, append the DDC.swift bullet only. Do not duplicate the AskForPermission or Sparkle entries.

- [ ] **Step 17.2: Commit**

```bash
git add README.md README.zh-CN.md
git commit -m "docs: credit DDC.swift in README acknowledgements"
```

---

## Task 18 — Final verification

**Files:** none

- [ ] **Step 18.1: Full test suite**

```bash
swift test 2>&1 | tail -20
```

Expected: all tests pass. If any pre-existing test fails, investigate (do not paper over by editing the test).

- [ ] **Step 18.2: Clean build**

```bash
swift build -c release 2>&1 | tail -10
```

Expected: succeeds.

- [ ] **Step 18.3: Manual QA checklist (recorded only; pass/fail per item)**

Record results in the PR description. Each item is a separate observable check:

- [ ] Single supported external display: hover panel shows correct current brightness; drag slider updates display.
- [ ] Display reporting no DDC: card visible, greyed, slider disabled.
- [ ] Mixed (one supported, one not): per-card behaviour correct.
- [ ] Hot-plug a display while popover is open: list updates within ~1 s.
- [ ] Bind brightness ± hotkey in panel settings, conflict alert shows on collision.
- [ ] Hotkey press: native chiclet OSD appears; brightness changes on the display under the mouse.
- [ ] Hotkey press with cursor on built-in display: falls back to main external display.
- [ ] Popover open + hotkey press: slider value updates live.
- [ ] Restart AnyDoor: brightness on displays NOT overwritten (matches whatever the user / monitor was at).

- [ ] **Step 18.4: Final commit (optional, only if QA reveals trivial fixes)**

If QA pass requires any small fixes, batch them and commit:

```bash
git add .
git commit -m "fix(brightness): QA round-1 polish"
```
