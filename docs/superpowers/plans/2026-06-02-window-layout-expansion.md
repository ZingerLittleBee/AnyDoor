# Window Layout Expansion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 13 new window-layout actions (top/bottom halves, four quarters, three thirds, two two-thirds, and next/previous-display moves) as discrete, hotkey-bindable items inside the existing Window Layout submenu.

**Architecture:** Thread one new action vocabulary through the existing pipeline: `WindowLayoutAction` enum → pure `WindowLayoutGeometry` math → `WindowLayoutService` AX bridge → per-action `WindowLayoutProvider` → `BuiltinItem` catalog → `PanelStore` submenu partition. Pure-rect actions extend `targetRect`; cross-display moves use a new proportional-remap function. No new architectural layers.

**Tech Stack:** Swift 6.2, SwiftUI, SwiftData, Accessibility API (AX), XCTest, SPM.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Sources/AnyDoor/Services/WindowLayoutService.swift` | `WindowLayoutAction` enum, pure `WindowLayoutGeometry`, AX bridge | Modify |
| `Sources/AnyDoor/Services/Providers/WindowLayoutProvider.swift` | Action → toast mapping | Modify |
| `Sources/AnyDoor/Models/BuiltinItem.swift` | Built-in catalog (kind/title/symbol/order) | Modify |
| `Sources/AnyDoor/Utilities/L10n.swift` | Localization key enum | Modify |
| `Sources/AnyDoor/Resources/Localizable.xcstrings` | en + zh-Hans strings | Modify |
| `Sources/AnyDoor/Services/PanelStore.swift` | `windowLayoutChildKeys` set | Modify |
| `Sources/AnyDoor/AppDelegate.swift` | Provider registry | Modify |
| `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` | v2 order backfill | Modify |
| `Tests/AnyDoorTests/WindowLayoutGeometryTests.swift` | Geometry unit tests | Modify |
| `Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift` | Seeder backfill tests | Modify |

Action order is fixed so each task leaves the build green: geometry first (self-contained), then localization keys, then the catalog that depends on them, then service/provider wiring, then panel/registry, then seeder.

---

## Task 1: Pure-rect geometry + action enum

**Files:**
- Modify: `Sources/AnyDoor/Services/WindowLayoutService.swift:12-26` (enum), `:36-68` (geometry), add `movesDisplay`
- Test: `Tests/AnyDoorTests/WindowLayoutGeometryTests.swift`

- [ ] **Step 1: Write failing tests for the new pure-rect cases**

Append these methods inside `WindowLayoutGeometryTests` (before the closing brace). They reuse the existing `visible = CGRect(x: 0, y: 25, width: 1440, height: 875)` fixture.

```swift
    // MARK: - Halves (top/bottom)

    func testTopHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .topHalf, windowFrame: window, visibleFrame: visible
        )
        // floor(875/2) == 437, anchored at the visible top.
        XCTAssertEqual(target, CGRect(x: 0, y: 25, width: 1440, height: 437))
    }

    func testBottomHalf() {
        let window = CGRect(x: 100, y: 100, width: 400, height: 300)
        let target = WindowLayoutGeometry.targetRect(
            action: .bottomHalf, windowFrame: window, visibleFrame: visible
        )
        // height 437, bottom-anchored: maxY (900) - 437 == 463.
        XCTAssertEqual(target, CGRect(x: 0, y: 463, width: 1440, height: 437))
    }

    func testTopAndBottomHalvesDoNotOverlap() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let top = WindowLayoutGeometry.targetRect(action: .topHalf, windowFrame: window, visibleFrame: visible)
        let bottom = WindowLayoutGeometry.targetRect(action: .bottomHalf, windowFrame: window, visibleFrame: visible)
        XCTAssertLessThanOrEqual(top.maxY, bottom.minY, "halves must not overlap")
        XCTAssertEqual(top.minY, visible.minY)
        XCTAssertEqual(bottom.maxY, visible.maxY)
    }

    // MARK: - Quarters

    func testTopLeftQuarter() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = WindowLayoutGeometry.targetRect(action: .topLeftQuarter, windowFrame: window, visibleFrame: visible)
        // floor(1440/2)=720, floor(875/2)=437, anchored top-left.
        XCTAssertEqual(target, CGRect(x: 0, y: 25, width: 720, height: 437))
    }

    func testBottomRightQuarterMeetsTopLeft() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tl = WindowLayoutGeometry.targetRect(action: .topLeftQuarter, windowFrame: window, visibleFrame: visible)
        let br = WindowLayoutGeometry.targetRect(action: .bottomRightQuarter, windowFrame: window, visibleFrame: visible)
        // Right column starts at maxX - 720; bottom row starts at maxY - 437.
        XCTAssertEqual(br, CGRect(x: 720, y: 463, width: 720, height: 437))
        XCTAssertLessThanOrEqual(tl.maxX, br.minX, "columns must not overlap")
        XCTAssertLessThanOrEqual(tl.maxY, br.minY, "rows must not overlap")
        XCTAssertEqual(br.maxX, visible.maxX)
        XCTAssertEqual(br.maxY, visible.maxY)
    }

    func testTopRightAndBottomLeftQuarters() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let tr = WindowLayoutGeometry.targetRect(action: .topRightQuarter, windowFrame: window, visibleFrame: visible)
        let bl = WindowLayoutGeometry.targetRect(action: .bottomLeftQuarter, windowFrame: window, visibleFrame: visible)
        XCTAssertEqual(tr, CGRect(x: 720, y: 25, width: 720, height: 437))
        XCTAssertEqual(bl, CGRect(x: 0, y: 463, width: 720, height: 437))
    }

    // MARK: - Thirds (tile the full width exactly)

    func testThirdsTileFullWidth() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftThird, windowFrame: window, visibleFrame: visible)
        let center = WindowLayoutGeometry.targetRect(action: .centerThird, windowFrame: window, visibleFrame: visible)
        let right = WindowLayoutGeometry.targetRect(action: .rightThird, windowFrame: window, visibleFrame: visible)
        // floor(1440/3) == 480 each; full height.
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 480, height: 875))
        XCTAssertEqual(right.maxX, visible.maxX)
        // Center fills the gap between left.maxX and right.minX exactly.
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.maxX, right.minX)
        // No gaps, no overlaps across the whole width.
        XCTAssertEqual(left.minX, visible.minX)
    }

    func testThirdsTileNonDivisibleWidth() {
        // 1000 / 3 -> floor 333; center must absorb the remainder so the
        // three columns still cover [0, 1000] with no gap.
        let odd = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftThird, windowFrame: window, visibleFrame: odd)
        let center = WindowLayoutGeometry.targetRect(action: .centerThird, windowFrame: window, visibleFrame: odd)
        let right = WindowLayoutGeometry.targetRect(action: .rightThird, windowFrame: window, visibleFrame: odd)
        XCTAssertEqual(left.minX, 0)
        XCTAssertEqual(right.maxX, 1000)
        XCTAssertEqual(center.minX, left.maxX)
        XCTAssertEqual(center.maxX, right.minX)
        XCTAssertEqual(center.width, 1000 - left.width - right.width)
    }

    // MARK: - Two-thirds

    func testTwoThirds() {
        let window = CGRect(x: 0, y: 0, width: 100, height: 100)
        let left = WindowLayoutGeometry.targetRect(action: .leftTwoThirds, windowFrame: window, visibleFrame: visible)
        let right = WindowLayoutGeometry.targetRect(action: .rightTwoThirds, windowFrame: window, visibleFrame: visible)
        // floor(1440 * 2 / 3) == 960.
        XCTAssertEqual(left, CGRect(x: 0, y: 25, width: 960, height: 875))
        XCTAssertEqual(right, CGRect(x: 480, y: 25, width: 960, height: 875))
        XCTAssertEqual(right.maxX, visible.maxX)
    }
```

- [ ] **Step 2: Run the tests to verify they fail to compile**

Run: `swift test --filter WindowLayoutGeometryTests 2>&1 | tail -20`
Expected: FAIL — compiler errors like `type 'WindowLayoutAction' has no member 'topHalf'`. (Compilation failure is the expected "red" state.)

- [ ] **Step 3: Add the new enum cases and `movesDisplay`**

In `WindowLayoutService.swift`, replace the enum body (lines 12-26). Update the doc comment above it (lines 7-11) to drop the "thirds/multi-display out of scope" sentence.

```swift
/// A single, atomic window layout operation requested by the user.
///
/// Covers Rectangle-style tiling against the focused window: halves,
/// quarters, thirds, two-thirds, plus next/previous-display moves.
/// Restore-previous-size and cycle behavior are intentionally out of scope.
enum WindowLayoutAction: String, Sendable, CaseIterable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeftQuarter
    case topRightQuarter
    case bottomLeftQuarter
    case bottomRightQuarter
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case rightTwoThirds
    case maximize
    case center
    case moveToNextDisplay
    case moveToPreviousDisplay

    /// True only for actions whose target is a different display. The service
    /// routes these through `WindowLayoutGeometry.rectMovingToDisplay` instead
    /// of `targetRect`.
    var movesDisplay: Bool {
        switch self {
        case .moveToNextDisplay, .moveToPreviousDisplay: return true
        default: return false
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf:            return "rectangle.lefthalf.filled"
        case .rightHalf:           return "rectangle.righthalf.filled"
        case .topHalf:             return "rectangle.tophalf.filled"
        case .bottomHalf:          return "rectangle.bottomhalf.filled"
        case .topLeftQuarter:      return "square.split.2x2"
        case .topRightQuarter:     return "square.split.2x2"
        case .bottomLeftQuarter:   return "square.split.2x2"
        case .bottomRightQuarter:  return "square.split.2x2"
        case .leftThird:           return "rectangle.split.3x1"
        case .centerThird:         return "rectangle.split.3x1"
        case .rightThird:          return "rectangle.split.3x1"
        case .leftTwoThirds:       return "rectangle.split.3x1"
        case .rightTwoThirds:      return "rectangle.split.3x1"
        case .maximize:            return "arrow.up.left.and.arrow.down.right"
        case .center:              return "rectangle.center.inset.filled"
        case .moveToNextDisplay:   return "rectangle.on.rectangle"
        case .moveToPreviousDisplay: return "rectangle.on.rectangle"
        }
    }
}
```

Note: `WindowLayoutAction.symbol` is not the panel glyph (that is `BuiltinItem.symbol`, set in Task 4). It is kept consistent but unused by the UI; do not delete it.

- [ ] **Step 4: Extend `targetRect` with the new pure-rect cases**

In `WindowLayoutGeometry.targetRect` (lines 36-68), insert the new cases. Keep the existing `.leftHalf/.rightHalf/.maximize/.center` cases unchanged. Add a fallback for the `movesDisplay` cases (they never reach here — see Task 3 — but the switch must be exhaustive).

```swift
        case .topHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: visibleFrame.width, height: half)
        case .bottomHalf:
            let half = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - half,
                          width: visibleFrame.width, height: half)
        case .topLeftQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY, width: w, height: h)
        case .topRightQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.maxX - w, y: visibleFrame.minY, width: w, height: h)
        case .bottomLeftQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.maxY - h, width: w, height: h)
        case .bottomRightQuarter:
            let w = floor(visibleFrame.width / 2), h = floor(visibleFrame.height / 2)
            return CGRect(x: visibleFrame.maxX - w, y: visibleFrame.maxY - h, width: w, height: h)
        case .leftThird:
            let third = floor(visibleFrame.width / 3)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: third, height: visibleFrame.height)
        case .rightThird:
            let third = floor(visibleFrame.width / 3)
            return CGRect(x: visibleFrame.maxX - third, y: visibleFrame.minY,
                          width: third, height: visibleFrame.height)
        case .centerThird:
            // Center absorbs the rounding remainder so left|center|right tile
            // the full width exactly: span from left third's right edge to
            // right third's left edge.
            let third = floor(visibleFrame.width / 3)
            let minX = visibleFrame.minX + third
            let maxX = visibleFrame.maxX - third
            return CGRect(x: minX, y: visibleFrame.minY,
                          width: maxX - minX, height: visibleFrame.height)
        case .leftTwoThirds:
            let twoThirds = floor(visibleFrame.width * 2 / 3)
            return CGRect(x: visibleFrame.minX, y: visibleFrame.minY,
                          width: twoThirds, height: visibleFrame.height)
        case .rightTwoThirds:
            let twoThirds = floor(visibleFrame.width * 2 / 3)
            return CGRect(x: visibleFrame.maxX - twoThirds, y: visibleFrame.minY,
                          width: twoThirds, height: visibleFrame.height)
        case .moveToNextDisplay, .moveToPreviousDisplay:
            // Display-moving actions never reach targetRect; the service
            // routes them to rectMovingToDisplay. Harmless identity fallback.
            return visibleFrame
```

- [ ] **Step 5: Run the geometry tests to verify they pass**

Run: `swift test --filter WindowLayoutGeometryTests 2>&1 | tail -15`
Expected: PASS — all new and existing geometry tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/WindowLayoutService.swift Tests/AnyDoorTests/WindowLayoutGeometryTests.swift
git commit -m "feat(window-layout): add halves, quarters, thirds, two-thirds geometry"
```

---

## Task 2: Cross-display proportional remap

**Files:**
- Modify: `Sources/AnyDoor/Services/WindowLayoutService.swift` (add `rectMovingToDisplay` + `wrappedIndex` to `WindowLayoutGeometry`)
- Test: `Tests/AnyDoorTests/WindowLayoutGeometryTests.swift`

- [ ] **Step 1: Write failing tests for remap + index wrap**

Append inside `WindowLayoutGeometryTests`:

```swift
    // MARK: - Cross-display remap

    func testRemapSameSizeDisplaysPreservesRelativeFrame() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 2000, y: 0, width: 1000, height: 800)
        let window = CGRect(x: 100, y: 80, width: 400, height: 300)
        let result = WindowLayoutGeometry.rectMovingToDisplay(
            windowFrame: window, fromVisible: from, toVisible: to)
        // Same size: shift by the origin delta, size unchanged.
        XCTAssertEqual(result, CGRect(x: 2100, y: 80, width: 400, height: 300))
    }

    func testRemapScalesToSmallerDisplay() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 1000, y: 0, width: 500, height: 400)  // half size
        let window = CGRect(x: 200, y: 200, width: 400, height: 400)
        let result = WindowLayoutGeometry.rectMovingToDisplay(
            windowFrame: window, fromVisible: from, toVisible: to)
        // Proportions: x 20% -> 1000 + 0.2*500 = 1100; y 25% -> 100;
        // width 40% -> 200; height 50% -> 200.
        XCTAssertEqual(result, CGRect(x: 1100, y: 100, width: 200, height: 200))
    }

    func testRemapClampsOversizedResultIntoDestination() {
        let from = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let to = CGRect(x: 1000, y: 0, width: 600, height: 500)
        // Window fills the source entirely -> would fill destination; ensure it
        // stays within destination bounds.
        let window = from
        let result = WindowLayoutGeometry.rectMovingToDisplay(
            windowFrame: window, fromVisible: from, toVisible: to)
        XCTAssertEqual(result, to)
    }

    func testRemapZeroSizedSourceFallsBackToDestinationOrigin() {
        let from = CGRect(x: 0, y: 0, width: 0, height: 0)
        let to = CGRect(x: 500, y: 500, width: 800, height: 600)
        let window = CGRect(x: 10, y: 10, width: 300, height: 200)
        let result = WindowLayoutGeometry.rectMovingToDisplay(
            windowFrame: window, fromVisible: from, toVisible: to)
        // Degenerate source: place at destination origin, keep clamped size.
        XCTAssertEqual(result, CGRect(x: 500, y: 500, width: 300, height: 200))
    }

    func testWrappedIndexNextAndPrevious() {
        XCTAssertEqual(WindowLayoutGeometry.wrappedIndex(current: 0, delta: 1, count: 3), 1)
        XCTAssertEqual(WindowLayoutGeometry.wrappedIndex(current: 2, delta: 1, count: 3), 0)
        XCTAssertEqual(WindowLayoutGeometry.wrappedIndex(current: 0, delta: -1, count: 3), 2)
        XCTAssertEqual(WindowLayoutGeometry.wrappedIndex(current: 1, delta: -1, count: 3), 0)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WindowLayoutGeometryTests 2>&1 | tail -15`
Expected: FAIL — `WindowLayoutGeometry` has no member `rectMovingToDisplay` / `wrappedIndex`.

- [ ] **Step 3: Implement the remap + wrap helpers**

Add inside `enum WindowLayoutGeometry` (after `targetRect`, before the closing brace):

```swift
    /// Map a window from its source display's visible region into a
    /// destination display's visible region, preserving relative position and
    /// relative size (Rectangle-default proportional remap), then clamp the
    /// result fully inside `toVisible`.
    ///
    /// All rects are in AX coordinates (top-left origin). A degenerate source
    /// (zero width/height) falls back to the destination origin with the
    /// window's original size, clamped to the destination.
    static func rectMovingToDisplay(
        windowFrame: CGRect,
        fromVisible: CGRect,
        toVisible: CGRect
    ) -> CGRect {
        guard fromVisible.width > 0, fromVisible.height > 0 else {
            let w = min(windowFrame.width, toVisible.width)
            let h = min(windowFrame.height, toVisible.height)
            return CGRect(origin: toVisible.origin, size: CGSize(width: w, height: h))
        }
        let fx = (windowFrame.minX - fromVisible.minX) / fromVisible.width
        let fy = (windowFrame.minY - fromVisible.minY) / fromVisible.height
        let fw = windowFrame.width / fromVisible.width
        let fh = windowFrame.height / fromVisible.height

        var width = min(fw * toVisible.width, toVisible.width)
        var height = min(fh * toVisible.height, toVisible.height)
        var x = toVisible.minX + fx * toVisible.width
        var y = toVisible.minY + fy * toVisible.height

        // Clamp origin so the rect stays fully inside the destination.
        x = min(max(x, toVisible.minX), toVisible.maxX - width)
        y = min(max(y, toVisible.minY), toVisible.maxY - height)
        // Guard against negative dimensions from pathological inputs.
        width = max(width, 0)
        height = max(height, 0)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Index arithmetic for next/previous-display selection with wrap-around.
    /// `delta` is +1 (next) or -1 (previous). `count` must be >= 1.
    static func wrappedIndex(current: Int, delta: Int, count: Int) -> Int {
        let raw = (current + delta) % count
        return raw < 0 ? raw + count : raw
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WindowLayoutGeometryTests 2>&1 | tail -15`
Expected: PASS — all remap and wrap tests green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/WindowLayoutService.swift Tests/AnyDoorTests/WindowLayoutGeometryTests.swift
git commit -m "feat(window-layout): add cross-display proportional remap geometry"
```

---

## Task 3: Localization keys + strings

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift` (add `Key` cases)
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings` (add en + zh-Hans entries)

- [ ] **Step 1: Add the `L10n.Key` cases**

In `L10n.swift`, the `Key` enum is alphabetized by raw value. Insert these cases in alphabetical position among the existing `builtin*` cases (after `builtinAutoHideMenuBar`, etc.; exact ordering only affects readability, not behavior):

```swift
        case builtinWindowBottomHalf = "builtin.windowBottomHalf"
        case builtinWindowBottomLeftQuarter = "builtin.windowBottomLeftQuarter"
        case builtinWindowBottomRightQuarter = "builtin.windowBottomRightQuarter"
        case builtinWindowCenterThird = "builtin.windowCenterThird"
        case builtinWindowLeftThird = "builtin.windowLeftThird"
        case builtinWindowLeftTwoThirds = "builtin.windowLeftTwoThirds"
        case builtinWindowMoveNextDisplay = "builtin.windowMoveNextDisplay"
        case builtinWindowMovePreviousDisplay = "builtin.windowMovePreviousDisplay"
        case builtinWindowRightThird = "builtin.windowRightThird"
        case builtinWindowRightTwoThirds = "builtin.windowRightTwoThirds"
        case builtinWindowTopHalf = "builtin.windowTopHalf"
        case builtinWindowTopLeftQuarter = "builtin.windowTopLeftQuarter"
        case builtinWindowTopRightQuarter = "builtin.windowTopRightQuarter"
```

And add the single new toast key alongside the existing `toastWindowLayout*` cases (after line 211):

```swift
        case toastWindowLayoutSingleDisplay = "toast.windowLayout.singleDisplay"
```

- [ ] **Step 2: Add the xcstrings entries**

In `Localizable.xcstrings`, add one entry per key under `"strings"`. Match the existing format exactly (`extractionState: "manual"`, `en` + `zh-Hans` `stringUnit`s with `state: "translated"`). Add:

| Key | en | zh-Hans |
| --- | --- | --- |
| `builtin.windowTopHalf` | Top Half | 上半屏 |
| `builtin.windowBottomHalf` | Bottom Half | 下半屏 |
| `builtin.windowTopLeftQuarter` | Top Left | 左上角 |
| `builtin.windowTopRightQuarter` | Top Right | 右上角 |
| `builtin.windowBottomLeftQuarter` | Bottom Left | 左下角 |
| `builtin.windowBottomRightQuarter` | Bottom Right | 右下角 |
| `builtin.windowLeftThird` | Left Third | 左三分之一 |
| `builtin.windowCenterThird` | Center Third | 中三分之一 |
| `builtin.windowRightThird` | Right Third | 右三分之一 |
| `builtin.windowLeftTwoThirds` | Left Two Thirds | 左三分之二 |
| `builtin.windowRightTwoThirds` | Right Two Thirds | 右三分之二 |
| `builtin.windowMoveNextDisplay` | Move to Next Display | 移到下一显示器 |
| `builtin.windowMovePreviousDisplay` | Move to Previous Display | 移到上一显示器 |
| `toast.windowLayout.singleDisplay` | Only one display | 只有一个显示器 |

Example entry to copy (for `builtin.windowTopHalf`):

```json
    "builtin.windowTopHalf" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : {
          "stringUnit" : { "state" : "translated", "value" : "Top Half" }
        },
        "zh-Hans" : {
          "stringUnit" : { "state" : "translated", "value" : "上半屏" }
        }
      }
    },
```

- [ ] **Step 3: Verify JSON validity**

Run: `python3 -c "import json; json.load(open('Sources/AnyDoor/Resources/Localizable.xcstrings')); print('valid json')"`
Expected: `valid json`

- [ ] **Step 4: Build to verify the enum compiles**

Run: `swift build 2>&1 | tail -10`
Expected: Build succeeds (the new `Key` cases are not yet referenced; this confirms no syntax error).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(window-layout): add localization keys for new layout actions"
```

---

## Task 4: BuiltinItem catalog entries

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift` (enum cases + 4 switches)
- Test: `Tests/AnyDoorTests/BuiltinItemLocalizationTests.swift` (runs unchanged; iterates `allCases`)

- [ ] **Step 1: Add the 13 enum cases**

In `BuiltinItem.swift`, after `case windowCenter` (line 35) and before `case windowLayout` (line 36), insert:

```swift
    case windowTopHalf
    case windowBottomHalf
    case windowTopLeftQuarter
    case windowTopRightQuarter
    case windowBottomLeftQuarter
    case windowBottomRightQuarter
    case windowLeftThird
    case windowCenterThird
    case windowRightThird
    case windowLeftTwoThirds
    case windowRightTwoThirds
    case windowMoveNextDisplay
    case windowMovePreviousDisplay
```

- [ ] **Step 2: Extend the `kind` switch**

In the `kind` computed property, add all 13 to the `.action` group. Replace the existing window line in the `.action` case (line 53) so it reads:

```swift
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS, .clipboardWall,
             .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
             .windowTopHalf, .windowBottomHalf,
             .windowTopLeftQuarter, .windowTopRightQuarter,
             .windowBottomLeftQuarter, .windowBottomRightQuarter,
             .windowLeftThird, .windowCenterThird, .windowRightThird,
             .windowLeftTwoThirds, .windowRightTwoThirds,
             .windowMoveNextDisplay, .windowMovePreviousDisplay: return .action
```

- [ ] **Step 3: Extend the `titleKey` switch**

In `titleKey`, after `case .windowCenter:` (line 90), add:

```swift
        case .windowTopHalf:            return .builtinWindowTopHalf
        case .windowBottomHalf:         return .builtinWindowBottomHalf
        case .windowTopLeftQuarter:     return .builtinWindowTopLeftQuarter
        case .windowTopRightQuarter:    return .builtinWindowTopRightQuarter
        case .windowBottomLeftQuarter:  return .builtinWindowBottomLeftQuarter
        case .windowBottomRightQuarter: return .builtinWindowBottomRightQuarter
        case .windowLeftThird:          return .builtinWindowLeftThird
        case .windowCenterThird:        return .builtinWindowCenterThird
        case .windowRightThird:         return .builtinWindowRightThird
        case .windowLeftTwoThirds:      return .builtinWindowLeftTwoThirds
        case .windowRightTwoThirds:     return .builtinWindowRightTwoThirds
        case .windowMoveNextDisplay:    return .builtinWindowMoveNextDisplay
        case .windowMovePreviousDisplay: return .builtinWindowMovePreviousDisplay
```

- [ ] **Step 4: Extend the `symbol` switch**

In `symbol`, after `case .windowCenter:` (line 126), add. (SF Symbol corner/third names vary by OS; the values below render on macOS 14. Verify in the SF Symbols app during review; if any is unavailable substitute `macwindow` rather than shipping an empty glyph.)

```swift
        case .windowTopHalf: return "rectangle.tophalf.filled"
        case .windowBottomHalf: return "rectangle.bottomhalf.filled"
        case .windowTopLeftQuarter: return "square.split.2x2"
        case .windowTopRightQuarter: return "square.split.2x2"
        case .windowBottomLeftQuarter: return "square.split.2x2"
        case .windowBottomRightQuarter: return "square.split.2x2"
        case .windowLeftThird: return "rectangle.split.3x1"
        case .windowCenterThird: return "rectangle.split.3x1"
        case .windowRightThird: return "rectangle.split.3x1"
        case .windowLeftTwoThirds: return "rectangle.split.3x1"
        case .windowRightTwoThirds: return "rectangle.split.3x1"
        case .windowMoveNextDisplay: return "rectangle.on.rectangle"
        case .windowMovePreviousDisplay: return "rectangle.on.rectangle"
```

- [ ] **Step 5: Extend the `defaultOrder` switch**

In `defaultOrder`, change the existing four window lines and add the new ones so the popover order is: halves, quarters, thirds, two-thirds, maximize, center, displays. Replace lines 160-163 and add the new cases:

```swift
        case .windowLeftHalf:           return 2010
        case .windowRightHalf:          return 2020
        case .windowTopHalf:            return 2030
        case .windowBottomHalf:         return 2040
        case .windowTopLeftQuarter:     return 2050
        case .windowTopRightQuarter:    return 2060
        case .windowBottomLeftQuarter:  return 2070
        case .windowBottomRightQuarter: return 2080
        case .windowLeftThird:          return 2110
        case .windowCenterThird:        return 2120
        case .windowRightThird:         return 2130
        case .windowLeftTwoThirds:      return 2140
        case .windowRightTwoThirds:     return 2150
        case .windowMaximize:           return 2160
        case .windowCenter:             return 2170
        case .windowMoveNextDisplay:    return 2180
        case .windowMovePreviousDisplay: return 2190
```

(`historyKind`, `requiresAutomation`, `feedbackSound` all use `default:` and need no change. `defaultVisibility` switches on `kind`, so the new `.action` items default visible automatically.)

- [ ] **Step 6: Run the localization coverage tests**

Run: `swift test --filter "BuiltinItemLocalizationTests|LocalizationCoverageTests" 2>&1 | tail -15`
Expected: PASS — every `BuiltinItem` (including the 13 new) resolves to a translated key in en and zh-Hans. (If any fails, a string is missing from Task 3 — fix it there.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift
git commit -m "feat(window-layout): add catalog entries for new layout actions"
```

---

## Task 5: Service cross-display routing + provider toast

**Files:**
- Modify: `Sources/AnyDoor/Services/WindowLayoutService.swift` (`WindowLayoutError`, `apply`, screen helpers)
- Modify: `Sources/AnyDoor/Services/Providers/WindowLayoutProvider.swift` (`message(for:)`)

- [ ] **Step 1: Add the `singleDisplay` error case**

In `WindowLayoutService.swift`, add to `enum WindowLayoutError` (after `case noScreenAvailable`, line 79):

```swift
    case singleDisplay
```

- [ ] **Step 2: Refactor screen-picking into a reusable helper**

Replace the body of `visibleFrameInAXCoords(containing:)` (lines 228-250) to delegate to a new `sourceScreen(containing:)`, and add the helper. This keeps the single-screen path identical while exposing screen selection to the cross-display path.

```swift
    private func sourceScreen(containing windowAXFrame: CGRect) throws -> NSScreen {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            throw WindowLayoutError.noScreenAvailable
        }
        let primaryHeight = primary.frame.height
        var best: (screen: NSScreen, area: CGFloat)?
        for screen in screens {
            let frameAX = Self.toAXCoords(rect: screen.frame, primaryHeight: primaryHeight)
            let area = frameAX.intersection(windowAXFrame).standardized.area
            if best == nil || area > best!.area {
                best = (screen, area)
            }
        }
        return best?.screen ?? primary
    }

    private func visibleFrameInAXCoords(containing windowAXFrame: CGRect) throws -> CGRect {
        guard let primary = NSScreen.screens.first else {
            throw WindowLayoutError.noScreenAvailable
        }
        let screen = try sourceScreen(containing: windowAXFrame)
        return Self.toAXCoords(rect: screen.visibleFrame, primaryHeight: primary.frame.height)
    }
```

- [ ] **Step 3: Branch `apply` on `movesDisplay`**

In `apply(_:)`, after the `try assertNotFullScreen(window)` line (line 110), replace the rest of the function body (lines 112-127) with a branch:

```swift
        let currentFrame = try readFrame(of: window)

        let target: CGRect
        if action.movesDisplay {
            target = try displayMoveTarget(windowFrame: currentFrame, action: action)
        } else {
            let visible = try visibleFrameInAXCoords(containing: currentFrame)
            target = WindowLayoutGeometry.targetRect(
                action: action, windowFrame: currentFrame, visibleFrame: visible)
        }

        try writePosition(of: window, to: target.origin)
        try writeSize(of: window, to: target.size)
    }

    /// Compute the destination frame for a next/previous-display move.
    /// Orders displays left-to-right (visibleFrame.minX, ties by minY), finds
    /// the window's source display, then proportionally remaps onto the
    /// wrapped neighbor. Throws `singleDisplay` when only one display exists.
    private func displayMoveTarget(windowFrame: CGRect, action: WindowLayoutAction) throws -> CGRect {
        let screens = NSScreen.screens
        guard let primary = screens.first else {
            throw WindowLayoutError.noScreenAvailable
        }
        guard screens.count >= 2 else {
            throw WindowLayoutError.singleDisplay
        }
        let primaryHeight = primary.frame.height
        let ordered = screens.sorted {
            if $0.visibleFrame.minX != $1.visibleFrame.minX {
                return $0.visibleFrame.minX < $1.visibleFrame.minX
            }
            return $0.visibleFrame.minY < $1.visibleFrame.minY
        }
        let source = try sourceScreen(containing: windowFrame)
        guard let index = ordered.firstIndex(where: { $0 === source }) else {
            throw WindowLayoutError.noScreenAvailable
        }
        let delta = (action == .moveToNextDisplay) ? 1 : -1
        let destIndex = WindowLayoutGeometry.wrappedIndex(
            current: index, delta: delta, count: ordered.count)
        let fromVisible = Self.toAXCoords(rect: source.visibleFrame, primaryHeight: primaryHeight)
        let toVisible = Self.toAXCoords(rect: ordered[destIndex].visibleFrame, primaryHeight: primaryHeight)
        return WindowLayoutGeometry.rectMovingToDisplay(
            windowFrame: windowFrame, fromVisible: fromVisible, toVisible: toVisible)
    }
```

Note: the original `apply` ends at the old line 128 `}`. After this edit the function closes inside the new code above; remove the now-duplicate trailing brace from the original body if the editor leaves one. Verify with the build in Step 6.

- [ ] **Step 4: Map the new error to a toast in the provider**

In `WindowLayoutProvider.swift`, add a case to `message(for:)` (after `case .fullScreenWindowNotSupported`, line 55):

```swift
        case .singleDisplay:
            return L(.toastWindowLayoutSingleDisplay)
```

- [ ] **Step 5: Write a unit test for `displayMoveTarget` index/remap composition**

The AX bridge needs real windows, but the screen-ordering + wrap + remap math is already covered by `WindowLayoutGeometry` tests (Task 2). No new unit test is added here; correctness of `displayMoveTarget` is verified by the geometry tests plus the manual multi-display check in Task 8. (This step is a deliberate no-op acknowledgment — do not add a test that requires `NSScreen` mocking.)

- [ ] **Step 6: Build to verify compilation and exhaustiveness**

Run: `swift build 2>&1 | tail -15`
Expected: Build succeeds. (Confirms `WindowLayoutError` switch in the provider is exhaustive and `apply` braces are balanced.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/WindowLayoutService.swift Sources/AnyDoor/Services/Providers/WindowLayoutProvider.swift
git commit -m "feat(window-layout): route cross-display moves through AX bridge"
```

---

## Task 6: Panel partition + provider registration

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift:24-26` (`windowLayoutChildKeys`)
- Modify: `Sources/AnyDoor/AppDelegate.swift:90-93` (provider registry)
- Test: `Tests/AnyDoorTests/PanelStoreTests.swift` (runs unchanged)

- [ ] **Step 1: Add the 13 keys to `windowLayoutChildKeys`**

In `PanelStore.swift`, replace the set literal (lines 24-26):

```swift
    private static let windowLayoutChildKeys: Set<BuiltinItem> = [
        .windowLeftHalf, .windowRightHalf, .windowMaximize, .windowCenter,
        .windowTopHalf, .windowBottomHalf,
        .windowTopLeftQuarter, .windowTopRightQuarter,
        .windowBottomLeftQuarter, .windowBottomRightQuarter,
        .windowLeftThird, .windowCenterThird, .windowRightThird,
        .windowLeftTwoThirds, .windowRightTwoThirds,
        .windowMoveNextDisplay, .windowMovePreviousDisplay,
    ]
```

- [ ] **Step 2: Register the 13 providers**

In `AppDelegate.swift`, after the four existing `WindowLayoutProvider` lines (line 93), add:

```swift
            WindowLayoutProvider(item: .windowTopHalf, action: .topHalf),
            WindowLayoutProvider(item: .windowBottomHalf, action: .bottomHalf),
            WindowLayoutProvider(item: .windowTopLeftQuarter, action: .topLeftQuarter),
            WindowLayoutProvider(item: .windowTopRightQuarter, action: .topRightQuarter),
            WindowLayoutProvider(item: .windowBottomLeftQuarter, action: .bottomLeftQuarter),
            WindowLayoutProvider(item: .windowBottomRightQuarter, action: .bottomRightQuarter),
            WindowLayoutProvider(item: .windowLeftThird, action: .leftThird),
            WindowLayoutProvider(item: .windowCenterThird, action: .centerThird),
            WindowLayoutProvider(item: .windowRightThird, action: .rightThird),
            WindowLayoutProvider(item: .windowLeftTwoThirds, action: .leftTwoThirds),
            WindowLayoutProvider(item: .windowRightTwoThirds, action: .rightTwoThirds),
            WindowLayoutProvider(item: .windowMoveNextDisplay, action: .moveToNextDisplay),
            WindowLayoutProvider(item: .windowMovePreviousDisplay, action: .moveToPreviousDisplay),
```

- [ ] **Step 3: Build and run the panel tests**

Run: `swift test --filter PanelStoreTests 2>&1 | tail -15`
Expected: PASS — the new items partition into `windowLayoutChildren`, not `topLevelEntries`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(window-layout): register new actions in submenu and provider registry"
```

---

## Task 7: Seeder v2 order backfill

**Files:**
- Modify: `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift`
- Test: `Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift`

- [ ] **Step 1: Write a failing test for the v2 backfill**

Append to `WindowLayoutSeederBackfillTests`. Add the v2 flag key to setUp/tearDown cleanup too.

First, add the flag constant and extend cleanup. Change the top of the class:

```swift
final class WindowLayoutSeederBackfillTests: XCTestCase {
    private let flagKey = "windowLayoutDefaultsApplied_v1"
    private let flagKeyV2 = "windowLayoutDefaultsApplied_v2"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKeyV2)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: flagKey)
        UserDefaults.standard.removeObject(forKey: flagKeyV2)
        super.tearDown()
    }
```

Then add the new test method:

```swift
    @MainActor
    func testV2BackfillReordersAllWindowChildren() throws {
        let ctx = try makeInMemoryContext()

        // Simulate an upgrade: the four legacy children exist with v1 orders,
        // and the 13 new children were just appended by the seeder at large
        // arbitrary orders.
        let seeded: [(String, Double)] = [
            ("windowLeftHalf", 2010), ("windowRightHalf", 2020),
            ("windowMaximize", 2030), ("windowCenter", 2040),
            ("windowTopHalf", 9000), ("windowBottomHalf", 9100),
            ("windowMoveNextDisplay", 9200),
        ]
        for (key, order) in seeded {
            ctx.insert(BuiltinPreference(itemKey: key, isVisible: true, displayOrder: order))
        }
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let rows = try ctx.fetch(FetchDescriptor<BuiltinPreference>())
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.itemKey, $0.displayOrder) })
        XCTAssertEqual(byKey["windowTopHalf"], 2030)
        XCTAssertEqual(byKey["windowBottomHalf"], 2040)
        XCTAssertEqual(byKey["windowMaximize"], 2160)
        XCTAssertEqual(byKey["windowCenter"], 2170)
        XCTAssertEqual(byKey["windowMoveNextDisplay"], 2180)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: flagKeyV2))
    }

    @MainActor
    func testV2BackfillIsOneShot() throws {
        let ctx = try makeInMemoryContext()
        ctx.insert(BuiltinPreference(itemKey: "windowMaximize", isVisible: true, displayOrder: 2160))
        try ctx.save()
        UserDefaults.standard.set(true, forKey: flagKeyV2)

        // Manually corrupt the order; backfill must NOT run again.
        let row = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).first { $0.itemKey == "windowMaximize" }
        row?.displayOrder = 5
        try ctx.save()

        BuiltinPreferenceSeeder.seedIfNeeded(in: ctx)

        let after = try ctx.fetch(FetchDescriptor<BuiltinPreference>()).first { $0.itemKey == "windowMaximize" }
        XCTAssertEqual(after?.displayOrder, 5, "v2 backfill must be one-shot")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter WindowLayoutSeederBackfillTests 2>&1 | tail -15`
Expected: FAIL — `windowTopHalf` still 9000 (no v2 backfill yet); flagKeyV2 false.

- [ ] **Step 3: Implement the v2 backfill**

In `BuiltinPreferenceSeeder.swift`, add the flag constant (after line 16):

```swift
    private static let windowLayoutBackfillV2Flag = "windowLayoutDefaultsApplied_v2"
```

Call it in `seedIfNeeded`, after `applyWindowLayoutBackfillIfNeeded(in: context)` (line 46):

```swift
            applyWindowLayoutBackfillV2IfNeeded(in: context)
```

Add the method (after `applyWindowLayoutBackfillIfNeeded`, before the closing brace of the enum):

```swift
    /// One-shot rewrite of all 17 window-layout children to the displayOrder
    /// introduced with the layout expansion. Fresh installs already get these
    /// via `defaultOrder`; this covers upgrades whose four legacy children
    /// were pinned by the v1 backfill and whose 13 new children were appended
    /// at arbitrary `maxOrder + 100` slots by the seeder.
    @MainActor
    private static func applyWindowLayoutBackfillV2IfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: windowLayoutBackfillV2Flag) else { return }

        let targets: [(BuiltinItem, Double)] = [
            (.windowLeftHalf, 2010), (.windowRightHalf, 2020),
            (.windowTopHalf, 2030), (.windowBottomHalf, 2040),
            (.windowTopLeftQuarter, 2050), (.windowTopRightQuarter, 2060),
            (.windowBottomLeftQuarter, 2070), (.windowBottomRightQuarter, 2080),
            (.windowLeftThird, 2110), (.windowCenterThird, 2120), (.windowRightThird, 2130),
            (.windowLeftTwoThirds, 2140), (.windowRightTwoThirds, 2150),
            (.windowMaximize, 2160), (.windowCenter, 2170),
            (.windowMoveNextDisplay, 2180), (.windowMovePreviousDisplay, 2190),
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
            defaults.set(true, forKey: windowLayoutBackfillV2Flag)
            logger.info("Applied windowLayout displayOrder backfill v2")
        } catch {
            logger.error("windowLayout backfill v2 failed: \(error)")
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter WindowLayoutSeederBackfillTests 2>&1 | tail -15`
Expected: PASS — both new tests and the existing v1 test green.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift Tests/AnyDoorTests/WindowLayoutSeederBackfillTests.swift
git commit -m "feat(window-layout): backfill display order for all 17 layout children"
```

---

## Task 8: Full verification, changelog, manual check

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass, no failures.

- [ ] **Step 2: Release build**

Run: `swift build -c release 2>&1 | tail -10`
Expected: Build succeeds with no warnings introduced by the new code.

- [ ] **Step 3: Add a CHANGELOG entry**

Under `## [Unreleased]` in `CHANGELOG.md`, add an `### Added` section:

```markdown
### Added

- Window layout: the Window Layout submenu gains 13 new actions — top and
  bottom halves, four quarter-screen corners, left/center/right thirds,
  left/right two-thirds, and move-to-next / move-to-previous display. Each is
  an independent, individually hotkey-bindable item. Tiling actions tile the
  visible region exactly (the center third absorbs rounding so columns never
  gap or overlap); display moves remap the focused window proportionally onto
  the neighboring screen, ordered left-to-right with wrap-around, and surface a
  toast when only one display is connected.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for window layout expansion"
```

- [ ] **Step 5: Manual verification (requires `make install` + accessibility grant)**

These cannot be unit-tested (AX needs real windows). Perform manually and confirm each:

Run: `make install`
Then, with a normal resizable window focused (e.g. Finder, Safari), bind or invoke each action via the Window Layout submenu and confirm:
- [ ] Top/bottom halves and four quarters tile correctly with no gap or overlap.
- [ ] Left/center/right thirds together cover the full width; two-thirds variants size correctly.
- [ ] With two displays: move-to-next and move-to-previous shift the window to the neighbor, scaled proportionally; repeated moves wrap around.
- [ ] With one display: a move action shows the "只有一个显示器" toast and does nothing.
- [ ] A full-screen (native green-button) window shows the existing full-screen toast for any action.

---

## Self-Review Notes

- **Spec coverage:** §1 enum/movesDisplay → Task 1; §2 pure-rect + remap → Tasks 1–2; §3 service routing + singleDisplay → Task 5; §4 provider toast → Task 5; §5 BuiltinItem → Task 4; §6 visibility/order + v2 backfill → Tasks 4 & 7; §7 localization → Task 3; §8 provider registration → Task 6; §9 PanelStore childKeys → Task 6; Testing section → Tasks 1, 2, 7 + manual in Task 8. All sections mapped.
- **Type consistency:** `WindowLayoutAction` case names (`topHalf`, `moveToNextDisplay`, …) used identically in Tasks 1, 5, 6. `BuiltinItem` case names (`windowTopHalf`, `windowMoveNextDisplay`, …) consistent across Tasks 4, 6, 7. `L10n.Key` raw values match xcstrings keys in Task 3 and `titleKey` returns in Task 4. `wrappedIndex` / `rectMovingToDisplay` signatures defined in Task 2, called in Task 5.
- **Display-move testing:** intentionally manual (Task 8) because `NSScreen` cannot be mocked; the underlying pure math is fully unit-tested in Task 2.
