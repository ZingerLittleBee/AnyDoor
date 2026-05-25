# Window Layout Submenu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse the four `windowLeftHalf` / `windowRightHalf` / `windowMaximize` / `windowCenter` top-level rows into a single `windowLayout` submenu whose hover popover lists the four children, while preserving each child's individual hotkey and adding drag-reorder support inside Settings.

**Architecture:** New `BuiltinItem.windowLayout` case (kind `.submenu`). `PanelStore` filters the four child cases out of `topLevelEntries` and exposes them through a new `windowLayoutChildren` property, sorted by `BuiltinPreference.displayOrder`. `MenuBarView` mounts a new `WindowLayoutPopoverView` for `.submenu(.windowLayout)` hover. `PanelSettingsView` inline-expands the parent row to show the four children with drag handles + hotkey recorders (no visibility toggle).

**Tech Stack:** Swift 6.2 (`.swiftLanguageMode(.v6)`), SwiftUI, SwiftData, `@Observable` `PanelStore`, existing `HoverPopover` infrastructure, XCTest.

Reference spec: `docs/superpowers/specs/2026-05-25-window-layout-submenu-design.md`

---

## File Structure

**Modify:**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `windowLayout` case; rewrite the four window children's `defaultOrder` to in-popover values.
- `Sources/AnyDoor/Utilities/L10n.swift` — add `builtinWindowLayout` key.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — add the new string entry.
- `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` — add one-shot `displayOrder` backfill for the four window children, gated on `UserDefaults` flag.
- `Sources/AnyDoor/Services/PanelStore.swift` — add `windowLayoutChildren`; update `rebuild()` to partition window children; add `reorderWindowChildren(by:)` mutation; force child visibility to true.
- `Sources/AnyDoor/Views/MenuBarView.swift` — wire `.submenu(.windowLayout)` branch in `mountPopoverContent(for:)`.
- `Sources/AnyDoor/Views/PanelSettingsView.swift` — inline-expand `windowLayout` row to show children with drag + hotkey, no visibility toggle.

**Create:**
- `Sources/AnyDoor/Views/WindowLayoutPopoverView.swift` — popover content view, reads `panel.windowLayoutChildren` and dispatches the action on tap.
- `Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift` — verifies the one-shot displayOrder reset only fires once and produces the expected order.

**Tests touched:**
- `Tests/AnyDoorTests/BuiltinPreferenceSeederTests.swift` — only impact is that `BuiltinItem.allCases.count` grows by 1; existing tests already use `BuiltinItem.allCases` and should still pass.

---

## Task 1: Add `BuiltinItem.windowLayout` case

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`

- [ ] **Step 1: Add the case to the enum declaration**

Add to the `BuiltinItem` enum (after `.windowCenter`):

```swift
case windowLayout
```

- [ ] **Step 2: Map the kind**

Update the `.submenu` branch in `var kind: Kind` to include `windowLayout`:

```swift
case .appShortcuts, .portManager, .windowLayout: return .submenu
```

- [ ] **Step 3: Map the title key**

Add a case to `var titleKey: L10n.Key`:

```swift
case .windowLayout:      return .builtinWindowLayout
```

- [ ] **Step 4: Map the SF symbol**

Add a case to `var symbol: String`:

```swift
case .windowLayout: return "macwindow"
```

- [ ] **Step 5: Set defaultOrder for the parent and re-slot the four children**

In `var defaultOrder: Double`, set:

```swift
case .windowLayout:    return 2000
case .windowLeftHalf:  return 100
case .windowRightHalf: return 200
case .windowMaximize:  return 300
case .windowCenter:    return 400
```

(The children's previous values 2000/2010/2020/2030 become 100/200/300/400 — these now represent in-popover order, not panel order. The parent takes the 2000 slot in the top-level panel.)

- [ ] **Step 6: Build to confirm exhaustiveness**

Run: `swift build`
Expected: builds with no errors. (`L10n.Key.builtinWindowLayout` will be added in Task 2 — if the build fails on that key, proceed to Task 2 first then return.)

If the build fails because `L10n.Key.builtinWindowLayout` is undefined, do Task 2 next and rerun build.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift
git commit -m "feat(builtin): add windowLayout submenu case and re-slot child order"
```

---

## Task 2: Add `builtinWindowLayout` localization

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the L10n.Key case**

In `L10n.swift`, add to the `Key` enum, alphabetically near the other `builtinWindow…` cases:

```swift
case builtinWindowLayout = "builtin.windowLayout"
```

- [ ] **Step 2: Add the xcstrings entry**

In `Localizable.xcstrings`, add a new top-level entry (the file uses alphabetical ordering — place it between `builtin.windowCenter` and `builtin.windowLeftHalf`):

```json
"builtin.windowLayout" : {
  "extractionState" : "manual",
  "localizations" : {
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Window Layout" } },
    "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "窗口布局" } }
  }
},
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Run localization coverage test**

Run: `swift test --filter LocalizationCoverageTests`
Expected: PASS (the test enumerates `BuiltinItem.allCases` and asserts each title key resolves).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "i18n(builtin): add windowLayout title key and translations"
```

---

## Task 3: Seeder one-shot backfill for window child displayOrder

**Files:**
- Modify: `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`
- Create: `Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift`

The existing seeder only inserts missing rows. Users who installed before this change already have `BuiltinPreference` rows for `windowLeftHalf`/.../`windowCenter` with the old `displayOrder` values (2000/2010/2020/2030). We need a one-shot pass that rewrites those to 100/200/300/400 so the popover shows them in the intended order. The flag lives in `UserDefaults.standard` under key `windowLayoutDefaultsApplied_v1`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift`:

```swift
import XCTest
import SwiftData
@testable import AnyDoor

final class WindowLayoutSeederBackfillTests: XCTestCase {
    private let flagKey = "windowLayoutDefaultsApplied_v1"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: flagKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        super.tearDown()
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let schema = Schema([
            KeyBinding.self,
            BuiltinPreference.self,
            ClipboardHistoryItem.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    @MainActor
    func testBackfillRewritesLegacyWindowChildOrder() throws {
        let ctx = try makeInMemoryContext()

        // Simulate legacy state: four window children with their old top-level orders.
        for (key, order) in [
            ("windowLeftHalf",  2000.0),
            ("windowRightHalf", 2010.0),
            ("windowMaximize",  2020.0),
            ("windowCenter",    2030.0),
        ] {
            ctx.insert(BuiltinPreference(itemKey: key,
                                         isVisible: true,
                                         displayOrder: order))
        }
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0.displayOrder) })
        XCTAssertEqual(byKey["windowLeftHalf"],  100)
        XCTAssertEqual(byKey["windowRightHalf"], 200)
        XCTAssertEqual(byKey["windowMaximize"],  300)
        XCTAssertEqual(byKey["windowCenter"],    400)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))
    }

    @MainActor
    func testBackfillRunsOnlyOnce() throws {
        let ctx = try makeInMemoryContext()

        // First run on an empty store seeds defaults (100/200/300/400) AND sets the flag.
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKey))

        // User reorders inside the popover: simulate by writing custom values.
        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        if let row = rows.first(where: { $0.itemKey == "windowLeftHalf" }) {
            row.displayOrder = 999
        }
        try ctx.save()

        // Second seeder call must not touch the user's custom value.
        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)
        let after = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let left = try XCTUnwrap(after.first { $0.itemKey == "windowLeftHalf" })
        XCTAssertEqual(left.displayOrder, 999)
    }
}
```

- [ ] **Step 2: Run the test and verify failure**

Run: `swift test --filter WindowLayoutSeederBackfillTests`
Expected: FAIL — `windowLeftHalf` order is `2000`, not `100`, because the seeder doesn't rewrite existing rows.

- [ ] **Step 3: Implement the backfill in the seeder**

Edit `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`. Add a private helper and a call from `seedIfNeeded`:

```swift
import SwiftData
import OSLog
import Foundation

private let logger = Logger(subsystem: "dev.bybee.AnyDoor", category: "seeder")

enum BuiltinPreferenceSeeder {
    private static let windowLayoutBackfillFlag = "windowLayoutDefaultsApplied_v1"

    @MainActor
    static func seedIfNeeded(in context: ModelContext) {
        do {
            let existing = try context.fetch(FetchDescriptor<BuiltinPreference>())
            let existingKeys = Set(existing.map(\.itemKey))
            let maxOrder = existing.map(\.displayOrder).max() ?? 0

            var addedAt = max(maxOrder + 100, 0)
            var added = 0
            for item in BuiltinItem.allCases {
                guard !existingKeys.contains(item.rawValue) else { continue }
                let order = existing.isEmpty ? item.defaultOrder : addedAt
                let pref = BuiltinPreference(
                    itemKey: item.rawValue,
                    isVisible: item.defaultVisibility,
                    displayOrder: order,
                    keyCode: nil,
                    modifierFlags: nil
                )
                context.insert(pref)
                addedAt += 100
                added += 1
            }
            if added > 0 {
                try context.save()
                logger.info("Seeded \(added) BuiltinPreference row(s)")
            }

            applyWindowLayoutBackfillIfNeeded(in: context)
        } catch {
            logger.error("BuiltinPreference seeding failed: \(error)")
        }
    }

    /// One-shot reset of the four window-children displayOrders to their new
    /// in-popover defaults (100/200/300/400). Pre-existing users had these
    /// items as top-level rows ordered 2000/2010/2020/2030; without this
    /// rewrite the popover would inherit the old spread and look identical
    /// for every user until they manually reorder.
    @MainActor
    private static func applyWindowLayoutBackfillIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: windowLayoutBackfillFlag) else { return }

        let targets: [(BuiltinItem, Double)] = [
            (.windowLeftHalf,  100),
            (.windowRightHalf, 200),
            (.windowMaximize,  300),
            (.windowCenter,    400),
        ]
        do {
            let rows = try context.fetch(FetchDescriptor<BuiltinPreference>())
            let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0) })
            for (item, order) in targets {
                if let row = byKey[item.rawValue] {
                    row.displayOrder = order
                }
            }
            try context.save()
            defaults.set(true, forKey: windowLayoutBackfillFlag)
            logger.info("Applied windowLayout displayOrder backfill")
        } catch {
            logger.error("windowLayout backfill failed: \(error)")
        }
    }
}
```

- [ ] **Step 4: Run the new tests and verify pass**

Run: `swift test --filter WindowLayoutSeederBackfillTests`
Expected: both tests PASS.

- [ ] **Step 5: Run the existing seeder tests for regression**

Run: `swift test --filter BuiltinPreferenceSeederTests`
Expected: all PASS (the new case bumps `allCases.count` by 1, which the existing test for "seeds all items on empty store" handles automatically).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift
git commit -m "feat(seeder): one-shot windowLayout displayOrder backfill"
```

---

## Task 4: `PanelStore.windowLayoutChildren` + rebuild partitioning

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`

- [ ] **Step 1: Add the published property**

In `PanelStore.swift`, add alongside `appShortcutChildren` (around line 18):

```swift
private(set) var windowLayoutChildren: [PanelEntry] = []
```

- [ ] **Step 2: Add a static set of window child cases**

Add at file scope inside the class (top of the class body):

```swift
private static let windowLayoutChildKeys: Set<BuiltinItem> = [
    .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
]
```

- [ ] **Step 3: Partition window children during rebuild**

In `func rebuild()` (around line 60), replace the top-level loop that appends to `topLevel` so window children are diverted into `windowLayoutChildren` instead. Inside the `for pref in prefs` block, change:

```swift
for pref in prefs {
    guard let item = BuiltinItem(rawValue: pref.itemKey) else { continue }
    if item.kind == .hiddenHotkey { continue }
    let hotkey = pref.keyCode.flatMap { code in
        pref.modifierFlags.map { mods in
            HotkeyDescriptor(keyCode: code, modifierFlags: mods)
        }
    }
    let isWindowChild = Self.windowLayoutChildKeys.contains(item)
    let entry = PanelEntry(
        id: PanelEntry.id(for: .builtin(item)),
        source: .builtin(item),
        displayOrder: pref.displayOrder,
        isVisible: isWindowChild ? true : pref.isVisible,
        hotkey: hotkey,
        title: "",
        subtitle: subtitle(for: item),
        symbol: item.symbol,
        kind: item.kind,
        toggleState: item.kind == .toggle ? toggleStates[item] : nil,
        permission: permissionStates[item] ?? (item.requiresAutomation ? .undetermined : .notRequired)
    )
    if isWindowChild {
        windowChildren.append(entry)
    } else {
        topLevel.append(entry)
    }
}
```

And declare `windowChildren` at the top of the method (next to `var topLevel: [PanelEntry] = []`):

```swift
var windowChildren: [PanelEntry] = []
```

- [ ] **Step 4: Assign windowLayoutChildren at end of rebuild**

At the bottom of `rebuild()` (just before the closing brace, after `self.appShortcutChildren = children`), add:

```swift
self.windowLayoutChildren = windowChildren.sorted { $0.displayOrder < $1.displayOrder }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(panel-store): partition window children into windowLayoutChildren"
```

---

## Task 5: `PanelStore.reorderWindowChildren(by:)` mutation

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`

- [ ] **Step 1: Add the mutation**

Insert after `reorderAppShortcuts(by:)` (around line 455):

```swift
/// Reorder the four window-layout children by new keys array (ordered).
///
/// Rewrites `BuiltinPreference.displayOrder` for each window child in
/// 100-step increments so the popover reflects the user's drag order
/// from the Settings panel. Non-window keys in `newOrder` are ignored.
func reorderWindowChildren(by newOrder: [BuiltinItem]) {
    guard let container = modelContainer else { return }
    let context = container.mainContext
    guard let prefs = try? context.fetch(FetchDescriptor<BuiltinPreference>()) else { return }
    let prefsByKey = Dictionary(uniqueKeysWithValues: prefs.map { ($0.itemKey, $0) })
    var order: Double = 100
    for item in newOrder {
        guard Self.windowLayoutChildKeys.contains(item) else { continue }
        if let pref = prefsByKey[item.rawValue] {
            pref.displayOrder = order
            order += 100
        }
    }
    try? context.save()
    rebuild()
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift
git commit -m "feat(panel-store): add reorderWindowChildren mutation"
```

---

## Task 6: `WindowLayoutPopoverView`

**Files:**
- Create: `Sources/AnyDoor/Views/WindowLayoutPopoverView.swift`

- [ ] **Step 1: Create the view**

Write the file:

```swift
import SwiftUI
import AppKit

/// Hover popover content for the Window Layout submenu. Lists the four
/// window-layout children with their assigned hotkeys; tapping a row
/// dispatches the matching action via `PanelStore.run`.
struct WindowLayoutPopoverView: View {
    let entries: [PanelEntry]
    var onHoverChange: (Bool) -> Void
    var onSelect: (BuiltinItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                LocalizedText(.builtinWindowLayout).font(.headline)
                Text(L(.panelAppShortcutCountSuffix, entries.count))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            if !entries.isEmpty {
                Divider().padding(.horizontal, 8)

                AdaptiveGlassEffectContainer(spacing: 2) {
                    VStack(spacing: 2) {
                        ForEach(entries) { entry in
                            if case let .builtin(item) = entry.source {
                                WindowLayoutRow(
                                    entry: entry,
                                    onSelect: { onSelect(item) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
            }
        }
        .frame(minWidth: 240, maxWidth: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onHover(perform: onHoverChange)
    }
}

private struct WindowLayoutRow: View {
    let entry: PanelEntry
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbol)
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
            Text(entry.localizedTitle())
                .font(.body)
                .lineLimit(1)
            Spacer(minLength: 12)
            if let hotkey = entry.hotkey {
                HotkeyLabel(hotkey: hotkey)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .adaptiveInteractiveSurface(cornerRadius: 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/WindowLayoutPopoverView.swift
git commit -m "feat(views): add WindowLayoutPopoverView"
```

---

## Task 7: Wire windowLayout hover popover in MenuBarView

**Files:**
- Modify: `Sources/AnyDoor/Views/MenuBarView.swift`

- [ ] **Step 1: Add the case in `mountPopoverContent(for:)`**

Find the existing `case .submenu(.portManager):` branch (around line 332). Add a new branch before the catch-all `case .submenu:` (around line 353):

```swift
case .submenu(.windowLayout):
    popover.needsKeyFocus = false
    popover.updateContent {
        WindowLayoutPopoverView(
            entries: panel.windowLayoutChildren,
            onHoverChange: { gate.popoverHover($0) },
            onSelect: { item in
                Task { await panel.run(item) }
                gate.reset()
                popover.hide()
                onRequestClose()
            }
        )
    }
    popover.show(anchoredTo: convertedTriggerFrame(for: target))
```

The `onRequestClose()` call mirrors how Clipboard History rows close the menu bar panel after an action; window layout actions move/resize the active window and the menu bar panel should dismiss so the layout change is visible.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Manual smoke test (CLI)**

Run: `swift run AnyDoor`
Verify (in the menu bar panel):
- A single "窗口布局" row replaces the four window rows.
- Hovering it opens a popover showing all four children in order: 左半屏 / 右半屏 / 最大化 / 居中.
- Clicking a child triggers the corresponding window layout action against the frontmost window and dismisses the panel.

Quit with `^C`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/MenuBarView.swift
git commit -m "feat(menubar): wire windowLayout hover popover"
```

---

## Task 8: Inline expansion in PanelSettingsView

**Files:**
- Modify: `Sources/AnyDoor/Views/PanelSettingsView.swift`

- [ ] **Step 1: Add the inline expansion branch**

In `row(for:)` (around line 47), add after the brightness branch:

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
        if case .builtin(.windowLayout) = entry.source {
            windowLayoutChildrenList()
        }
    }
    .opacity(entry.isVisible ? 1.0 : 0.5)
}
```

- [ ] **Step 2: Implement `windowLayoutChildrenList()`**

Add this method to the struct (near `appShortcutChildren()`):

```swift
@ViewBuilder
private func windowLayoutChildrenList() -> some View {
    ForEach(panel.windowLayoutChildren) { child in
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: 2).padding(.leading, 16)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: child.symbol).frame(width: 18)
            Text(child.localizedTitle()).font(.body)
            Spacer()
            HotkeyRecorder(hotkey: .constant(child.hotkey)) { newValue in
                handleHotkeyChange(entry: child, newValue: newValue)
            }
            .frame(width: 150, alignment: .trailing)
            Color.clear.frame(width: 20)
        }
        .padding(.vertical, 3)
    }
    .onMove(perform: moveWindowChildren)
}

private func moveWindowChildren(from source: IndexSet, to destination: Int) {
    var items = panel.windowLayoutChildren.compactMap { entry -> BuiltinItem? in
        if case let .builtin(item) = entry.source { return item } else { return nil }
    }
    items.move(fromOffsets: source, toOffset: destination)
    panel.reorderWindowChildren(by: items)
}
```

The layout mirrors `appShortcutChildren()`: indented accent bar, drag handle, SF symbol, title, hotkey recorder, and a 20-pt spacer to keep column alignment (children have no delete button).

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Manual smoke test**

Run: `swift run AnyDoor`
Open Settings → 面板 tab. Verify:
- The "窗口布局" row appears once, with the standard type badge "子菜单".
- Below it, four child rows are listed: 左半屏 / 右半屏 / 最大化 / 居中, each with a drag handle and a HotkeyRecorder; **no visibility checkbox**.
- Dragging a child row to a new position updates the order live, and reopening the panel hover popover shows the new order.
- Recording a hotkey on a child fires that layout action when pressed (test at least one).
- Hiding the parent row's panel-visibility checkbox hides the parent from the menu bar panel; the child hotkeys still fire.

Quit with `^C`.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/PanelSettingsView.swift
git commit -m "feat(settings): inline-expand windowLayout children with drag + hotkey"
```

---

## Task 9: Full regression pass

**Files:** (none modified)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: all tests PASS.

If any test fails because the assertion counts `BuiltinItem.allCases.count`, update the assertion to the new count (28).

- [ ] **Step 2: Release-mode build check**

Run: `swift build -c release`
Expected: succeeds.

- [ ] **Step 3: Manual regression — other submenus**

Run: `swift run AnyDoor`
Verify the existing submenu paths still work as before:
- App Shortcuts row hover opens the same popover as before, lists existing KeyBindings.
- Port Manager row hover opens the port manager popover with search focus.
- Brightness row hover opens the brightness slider popover.
- Clipboard-history hover rows (OCR / pick color / QR code / screenshot) still open their popovers.

Quit with `^C`.

- [ ] **Step 4: No commit required**

If anything regressed, fix and add a commit. Otherwise this task is verification-only.

---

## Self-Review

**Spec coverage:**
- `windowLayout` case added (Task 1) — ✓
- Child `defaultOrder` re-slotted (Task 1) — ✓
- L10n key + translations (Task 2) — ✓
- Seeder backfill with `windowLayoutDefaultsApplied_v1` flag (Task 3) — ✓
- `windowLayoutChildren` and partitioning in `rebuild()` (Task 4) — ✓
- `force isVisible = true` for window children (Task 4) — ✓
- `reorderWindowChildren` mutation (Task 5) — ✓
- `WindowLayoutPopoverView` (Task 6) — ✓
- Hover popover wiring in `MenuBarView` (Task 7) — ✓
- Settings inline expansion with drag + hotkey, no visibility toggle (Task 8) — ✓
- Children's hotkeys keep firing even with parent hidden — already true because `rebuildHotkeySnapshots()` iterates over all `BuiltinPreference` rows regardless of `isVisible`; verified manually in Task 8 Step 4.

**Placeholder scan:** no TBDs, no "add error handling" filler, all code blocks complete.

**Type consistency:** `reorderWindowChildren(by:)` matches the existing `reorderTopLevel(by:)` and `reorderAppShortcuts(by:)` naming; `windowLayoutChildren` matches `appShortcutChildren` naming. `windowLayoutChildrenList()` is the View helper (separate from the data property) to avoid name collision.

**Open risks:**
- Existing tests counting `BuiltinItem.allCases.count` will see 28 instead of 27. Task 9 catches this.
- The `onRequestClose()` call in the popover's `onSelect` (Task 7) is a UX choice — close the menu bar panel after a layout action. If the user prefers the panel to stay open, drop that line; see Task 7 Step 1.
