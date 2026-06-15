# Capture Selection — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the region screenshot "drag on an empty screen to create a
selection" with a pre-shown, mouse-adjustable selection rectangle (8 resize
handles + whole-rect move + empty-area new-drag), restored from the last
selection (persisted across launches) or a default centered rectangle.

**Architecture:** Add pure geometry helpers to `SelectionGeometry` (handle
layout, hit-testing, resize, restore-vs-default), persist the last rect in
`CaptureSettings`, rework the AppKit `SelectionOverlayView` mouse handling to
branch on a hit-test, and have `CaptureCoordinator` compute the initial rect and
persist on commit. The toolbar and the other capture types are Phase 2/3 — this
phase keeps `.region` only and confirms with **Enter** (Esc cancels).

**Tech Stack:** Swift 6.2 (strict concurrency), AppKit (`NSView`/`NSPanel`),
CoreGraphics, XCTest, SwiftPM (`swift build` / `swift test`).

**Scope note:** This plan is Phase 1 of the spec
`docs/superpowers/specs/2026-06-15-capture-selection-toolbar-design.md`. Phase 2
(attached toolbar + unified entry) and Phase 3 (scrolling/recording handoff) are
separate plans.

---

## File Structure

- Modify `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift` — add
  `SelectionHandle`, `SelectionHit`, `handleRects`, `hitTest`, `resizing`,
  `defaultCenteredRect`, `restoredRect`. Pure, unit-tested.
- Modify `Sources/AnyDoor/Services/Capture/CaptureSettings.swift` — add
  `lastRegionRect` persistence (`[Double]` `[x,y,w,h]`).
- Modify `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` — rework
  `SelectionOverlayView` mouse handling + draw handles + cursors; have
  `present` always pass a non-empty initial rect and key the panel that shows it.
- Modify `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift` — compute
  the initial rect, persist the committed rect, simplify `recapture`.
- Modify `Tests/AnyDoorTests/SelectionGeometryTests.swift` — tests for the new
  geometry.
- Modify `Tests/AnyDoorTests/CaptureSettingsTests.swift` — round-trip test for
  `lastRegionRect`.

All coordinates in the geometry helpers are y-up (AppKit bottom-left origin):
`maxY` is the visual top, `minY` the visual bottom.

---

### Task 1: Handle layout + hit-testing in SelectionGeometry

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift`
- Test: `Tests/AnyDoorTests/SelectionGeometryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/SelectionGeometryTests.swift` inside the class:

```swift
    // MARK: - Handles

    func testHandleRectsCenteredOnCornersAndEdges() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100) // maxX 300, maxY 200, mid (200,150)
        let h = SelectionGeometry.handleRects(for: rect, handleSize: 10)
        XCTAssertEqual(h.count, 8)
        XCTAssertEqual(h[.topLeft], CGRect(x: 95, y: 195, width: 10, height: 10))
        XCTAssertEqual(h[.bottomRight], CGRect(x: 295, y: 95, width: 10, height: 10))
        XCTAssertEqual(h[.right], CGRect(x: 295, y: 145, width: 10, height: 10))
        XCTAssertEqual(h[.top], CGRect(x: 195, y: 195, width: 10, height: 10))
    }

    func testHitTestPrioritizesHandlesThenInsideThenOutside() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 100, y: 200), in: rect, handleSize: 16), .handle(.topLeft))
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 200, y: 150), in: rect, handleSize: 16), .inside)
        XCTAssertEqual(SelectionGeometry.hitTest(CGPoint(x: 10, y: 10), in: rect, handleSize: 16), .outside)
    }
```

- [ ] **Step 2: Run the tests to verify they fail (red)**

Run: `swift test --filter SelectionGeometryTests 2>&1 | tail -20`
Expected: build fails — `type 'SelectionGeometry' has no member 'handleRects'`
(and `hitTest` / `SelectionHandle` / `SelectionHit` undefined). This compile
failure is the red state.

- [ ] **Step 3: Implement the types and functions**

Append to `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift`, **after**
the closing `}` of `enum SelectionGeometry`:

```swift
/// The eight resize anchors of a selection rectangle (y-up: `top` = maxY).
enum SelectionHandle: Equatable, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

/// The part of a selection a point lands on, used to route a mouse-down to
/// resize / move / create-new.
enum SelectionHit: Equatable {
    case handle(SelectionHandle)
    case inside
    case outside
}
```

Then add these methods **inside** `enum SelectionGeometry` (before its closing
`}`):

```swift
    /// The eight `handleSize`-square handle frames centered on the rect's
    /// corners and edge midpoints (y-up).
    static func handleRects(for rect: CGRect, handleSize: CGFloat) -> [SelectionHandle: CGRect] {
        let half = handleSize / 2
        func square(_ cx: CGFloat, _ cy: CGFloat) -> CGRect {
            CGRect(x: cx - half, y: cy - half, width: handleSize, height: handleSize)
        }
        return [
            .topLeft: square(rect.minX, rect.maxY),
            .top: square(rect.midX, rect.maxY),
            .topRight: square(rect.maxX, rect.maxY),
            .right: square(rect.maxX, rect.midY),
            .bottomRight: square(rect.maxX, rect.minY),
            .bottom: square(rect.midX, rect.minY),
            .bottomLeft: square(rect.minX, rect.minY),
            .left: square(rect.minX, rect.midY),
        ]
    }

    /// Classifies `p` against the selection: a handle (checked first, in a fixed
    /// order so overlaps are deterministic), the interior, or outside.
    static func hitTest(_ p: CGPoint, in rect: CGRect, handleSize: CGFloat) -> SelectionHit {
        let rects = handleRects(for: rect, handleSize: handleSize)
        for handle in SelectionHandle.allCases where rects[handle]?.contains(p) == true {
            return .handle(handle)
        }
        return rect.contains(p) ? .inside : .outside
    }
```

- [ ] **Step 4: Run the tests to verify they pass (green)**

Run: `swift test --filter SelectionGeometryTests 2>&1 | tail -20`
Expected: PASS (all `SelectionGeometryTests` green).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/SelectionGeometry.swift Tests/AnyDoorTests/SelectionGeometryTests.swift
git commit -m "feat(capture): add selection handle layout and hit-testing"
```

---

### Task 2: Resize + restore/default geometry in SelectionGeometry

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift`
- Test: `Tests/AnyDoorTests/SelectionGeometryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AnyDoorTests/SelectionGeometryTests.swift` inside the class:

```swift
    // MARK: - Handle resize

    func testResizingCornerKeepsOppositeAnchored() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100) // maxX 300, maxY 200
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = SelectionGeometry.resizing(rect, handle: .bottomLeft, to: CGPoint(x: 150, y: 120), in: bounds, minSize: 10)
        XCTAssertEqual(r, CGRect(x: 150, y: 120, width: 150, height: 80))
    }

    func testResizingEnforcesMinSizeAgainstOppositeEdge() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let r = SelectionGeometry.resizing(rect, handle: .right, to: CGPoint(x: 50, y: 150), in: bounds, minSize: 20)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 20, height: 100))
    }

    func testResizingClampsToBounds() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        let bounds = CGRect(x: 0, y: 0, width: 250, height: 250)
        let r = SelectionGeometry.resizing(rect, handle: .topRight, to: CGPoint(x: 400, y: 400), in: bounds, minSize: 10)
        XCTAssertEqual(r, CGRect(x: 100, y: 100, width: 150, height: 150))
    }

    // MARK: - Default + restore

    func testDefaultCenteredRectHalfSize() {
        let r = SelectionGeometry.defaultCenteredRect(in: CGRect(x: 0, y: 0, width: 1000, height: 800), fraction: 0.5)
        XCTAssertEqual(r, CGRect(x: 250, y: 200, width: 500, height: 400))
    }

    func testDefaultCenteredRectWithNegativeOrigin() {
        let r = SelectionGeometry.defaultCenteredRect(in: CGRect(x: -1000, y: 100, width: 800, height: 600), fraction: 0.5)
        XCTAssertEqual(r, CGRect(x: -800, y: 250, width: 400, height: 300))
    }

    func testRestoredRectOnlyWhenCenterOnADisplay() {
        let d1 = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let d2 = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let onD2 = CGRect(x: 1200, y: 100, width: 200, height: 100)
        XCTAssertEqual(SelectionGeometry.restoredRect(last: onD2, displays: [d1, d2]), onD2)
        XCTAssertNil(SelectionGeometry.restoredRect(last: CGRect(x: 5000, y: 100, width: 200, height: 100), displays: [d1, d2]))
        XCTAssertNil(SelectionGeometry.restoredRect(last: nil, displays: [d1, d2]))
    }
```

- [ ] **Step 2: Run the tests to verify they fail (red)**

Run: `swift test --filter SelectionGeometryTests 2>&1 | tail -20`
Expected: build fails — `type 'SelectionGeometry' has no member 'resizing'`
(and `defaultCenteredRect` / `restoredRect`).

- [ ] **Step 3: Implement the functions**

Add inside `enum SelectionGeometry` (before its closing `}`):

```swift
    /// Resizes `rect` by dragging `handle` to `point`, keeping the opposite
    /// edge/corner anchored, enforcing `minSize` per axis, and clamping the
    /// moving edges inside `bounds` (y-up).
    static func resizing(_ rect: CGRect, handle: SelectionHandle, to point: CGPoint, in bounds: CGRect, minSize: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX
        var minY = rect.minY, maxY = rect.maxY

        let movesLeft = handle == .topLeft || handle == .left || handle == .bottomLeft
        let movesRight = handle == .topRight || handle == .right || handle == .bottomRight
        let movesTop = handle == .topLeft || handle == .top || handle == .topRight
        let movesBottom = handle == .bottomLeft || handle == .bottom || handle == .bottomRight

        if movesLeft { minX = min(point.x, maxX - minSize) }
        if movesRight { maxX = max(point.x, minX + minSize) }
        if movesBottom { minY = min(point.y, maxY - minSize) }
        if movesTop { maxY = max(point.y, minY + minSize) }

        minX = max(minX, bounds.minX)
        maxX = min(maxX, bounds.maxX)
        minY = max(minY, bounds.minY)
        maxY = min(maxY, bounds.maxY)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A rectangle centered in `bounds`, each edge `fraction` of the
    /// corresponding bounds edge (fraction 0.5 = half width and half height).
    static func defaultCenteredRect(in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let w = bounds.width * fraction
        let h = bounds.height * fraction
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Returns `last` when its center lies within one of `displays`, else nil —
    /// used to decide whether a persisted selection can be restored.
    static func restoredRect(last: CGRect?, displays: [CGRect]) -> CGRect? {
        guard let last, !last.isEmpty else { return nil }
        let center = CGPoint(x: last.midX, y: last.midY)
        return displays.contains(where: { $0.contains(center) }) ? last : nil
    }
```

- [ ] **Step 4: Run the tests to verify they pass (green)**

Run: `swift test --filter SelectionGeometryTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/SelectionGeometry.swift Tests/AnyDoorTests/SelectionGeometryTests.swift
git commit -m "feat(capture): add selection resize and default/restore geometry"
```

---

### Task 3: Persist last region rect in CaptureSettings

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/CaptureSettings.swift`
- Test: `Tests/AnyDoorTests/CaptureSettingsTests.swift`

- [ ] **Step 1: Write the failing test**

Append inside the class in `Tests/AnyDoorTests/CaptureSettingsTests.swift`:

```swift
    func testLastRegionRectRoundTrip() {
        let d = makeDefaults()
        let s = CaptureSettings(defaults: d)
        XCTAssertNil(s.lastRegionRect)
        s.setLastRegionRect(CGRect(x: -120.5, y: 40, width: 300, height: 200))
        let reloaded = CaptureSettings(defaults: d)
        XCTAssertEqual(reloaded.lastRegionRect, CGRect(x: -120.5, y: 40, width: 300, height: 200))
    }
```

Add `import CoreGraphics` at the top of the file if not present (after
`import XCTest`).

- [ ] **Step 2: Run the test to verify it fails (red)**

Run: `swift test --filter CaptureSettingsTests 2>&1 | tail -20`
Expected: build fails — `value of type 'CaptureSettings' has no member 'lastRegionRect'`.

- [ ] **Step 3: Implement the persistence**

In `Sources/AnyDoor/Services/Capture/CaptureSettings.swift`:

Add the key next to the other `static let ...Key` declarations:

```swift
    static let lastRegionRectKey = "capture.lastRegionRect"
```

Add the stored property next to the other `private(set) var`s:

```swift
    private(set) var lastRegionRect: CGRect?
```

Add a private reader (place it just above `init`):

```swift
    private static func readRect(_ defaults: UserDefaults, _ key: String) -> CGRect? {
        guard let a = defaults.array(forKey: key) as? [Double], a.count == 4 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
```

In `init`, after the `overlayTimeout` line, add:

```swift
        self.lastRegionRect = Self.readRect(defaults, Self.lastRegionRectKey)
```

Add the setter next to the other `set...` methods:

```swift
    func setLastRegionRect(_ rect: CGRect) {
        lastRegionRect = rect
        defaults.set([Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)],
                     forKey: Self.lastRegionRectKey)
    }
```

In `reloadFromDefaults`, after the `overlayTimeout` line, add:

```swift
        lastRegionRect = Self.readRect(defaults, Self.lastRegionRectKey)
```

`CaptureSettings.swift` only `import Foundation` today; `CGRect`/`CGFloat` come
from CoreGraphics. Add `import CoreGraphics` under `import Foundation`.

- [ ] **Step 4: Run the test to verify it passes (green)**

Run: `swift test --filter CaptureSettingsTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureSettings.swift Tests/AnyDoorTests/CaptureSettingsTests.swift
git commit -m "feat(capture): persist last region selection across launches"
```

---

### Task 4: Always pre-show the initial rect; key the panel that holds it

**Files:**
- Modify: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift:24-82`

This task changes only `SelectionOverlayWindow.present` (the window manager), not
the view. After it, the per-screen panel that contains the initial rect becomes
key (so Enter/Esc reach the view showing the rect, even when the cursor is on
another display).

- [ ] **Step 1: Update `present` to choose the key panel by the initial rect**

In `present`, replace the trailing key-panel logic. Find:

```swift
            p.contentView = view
            p.orderFrontRegardless()
            // Make the panel under the cursor key so it receives Esc / arrow keys.
            if target.frame.contains(mouse) {
                p.makeKeyAndOrderFront(nil)
                p.makeFirstResponder(view)
            }
            panels.append(p)
        }
        // Fall back to keying the first panel if the cursor was off all displays.
        if !panels.contains(where: { $0.isKeyWindow }), let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
```

Replace with:

```swift
            p.contentView = view
            p.orderFrontRegardless()
            // Key the panel that shows the initial selection (so Enter/Esc/arrows
            // reach it); fall back to the panel under the cursor.
            let keyAnchor = initialRect.isEmpty ? mouse : CGPoint(x: initialRect.midX, y: initialRect.midY)
            if target.frame.contains(keyAnchor) {
                p.makeKeyAndOrderFront(nil)
                p.makeFirstResponder(view)
            }
            panels.append(p)
        }
        // Fall back to keying the first panel if the anchor was off all displays.
        if !panels.contains(where: { $0.isKeyWindow }), let first = panels.first {
            first.makeKeyAndOrderFront(nil)
            first.makeFirstResponder(first.contentView)
        }
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): key the overlay panel that holds the initial rect"
```

---

### Task 5: Rework SelectionOverlayView mouse handling (handles + move + new-drag)

**Files:**
- Modify: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` (the
  `SelectionOverlayView` class, ~lines 99-410)

Region mode now starts with a pre-shown rect; a mouse-down hit-tests it to
resize a handle, move the whole rect, or start a fresh selection on empty space.
Confirm is **Enter** (unchanged `keyDown`); `mouseUp` no longer commits region.
Window/fullscreen behavior is unchanged.

- [ ] **Step 1: Add interaction state + constants**

In `SelectionOverlayView`, next to the existing private stored properties
(`dragStart`, `currentRect`, `isDragging`, ...), add:

```swift
    /// Active mouse interaction for region mode.
    private enum DragMode: Equatable { case none, creating, moving, resizing(SelectionHandle) }
    private var dragMode: DragMode = .none
    /// Mouse point and rect captured at mouse-down, for move/resize math.
    private var dragOrigin: CGPoint = .zero
    private var rectAtDragStart: CGRect = .zero

    /// Handle sizes: a small drawn square, a larger invisible grab area.
    private static let handleVisualSize: CGFloat = 8
    private static let handleHitSize: CGFloat = 16

    private var isCreatingDrag: Bool { dragMode == .creating }
    private var showsLoupe: Bool {
        switch dragMode {
        case .creating: return true
        case .resizing: return true
        case .none, .moving: return false
        }
    }
```

- [ ] **Step 2: Replace `mouseDown`**

Find the current `mouseDown(with:)` and replace its whole body with:

```swift
    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        dragOrigin = p
        rectAtDragStart = currentRect

        if currentRect.isEmpty {
            beginCreating(at: p)
        } else {
            switch SelectionGeometry.hitTest(p, in: currentRect, handleSize: Self.handleHitSize) {
            case .handle(let h): dragMode = .resizing(h)
            case .inside: dragMode = .moving
            case .outside: beginCreating(at: p)
            }
        }
        isDragging = isCreatingDrag
        needsDisplay = true
    }

    private func beginCreating(at p: CGPoint) {
        dragMode = .creating
        dragStart = p
        currentRect = .zero
    }
```

- [ ] **Step 3: Replace `mouseDragged`**

Replace the whole body of `mouseDragged(with:)` with:

```swift
    override func mouseDragged(with event: NSEvent) {
        guard mode == .region else { return }
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        switch dragMode {
        case .creating:
            guard let start = dragStart else { return }
            currentRect = SelectionGeometry.clamped(SelectionGeometry.normalizedRect(from: start, to: p), to: bounds)
        case .moving:
            currentRect = SelectionGeometry.moved(rectAtDragStart, dx: p.x - dragOrigin.x, dy: p.y - dragOrigin.y, in: bounds)
        case .resizing(let h):
            currentRect = SelectionGeometry.resizing(rectAtDragStart, handle: h, to: p, in: bounds, minSize: SelectionGeometry.minimumEdge)
        case .none:
            break
        }
        needsDisplay = true
    }
```

- [ ] **Step 4: Replace `mouseUp`**

Replace the whole body of `mouseUp(with:)` with:

```swift
    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            let wasCreating = isCreatingDrag
            dragMode = .none
            isDragging = false
            // A too-small fresh drag resets to empty so the user can retry; an
            // adjusted pre-shown rect is kept. Commit happens on Enter (Phase 1).
            if wasCreating, SelectionGeometry.isTooSmall(currentRect) { currentRect = .zero }
            needsDisplay = true
        case .window:
            guard let win = hoveredWindow else { onCancel?(); return }
            onWindow?(win.id, globalScreenFrame(forCGWindow: win.frame))
        case .fullscreen:
            onCancel?()
        }
    }
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): hit-test selection for resize/move/new-drag"
```

---

### Task 6: Draw handles + hover cursors

**Files:**
- Modify: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` (the
  `SelectionOverlayView` class: `draw`, `mouseMoved`, `resetCursorRects`)

- [ ] **Step 1: Draw handles and gate crosshair/loupe on drag mode**

In `draw(_:)`, replace the `.region` case body. Find:

```swift
        case .region:
            if !currentRect.isEmpty {
                // Punch the selection back to full brightness by re-drawing the
                // bright frozen image clipped to the selection only.
                ctx.saveGState()
                ctx.clip(to: currentRect)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
                drawSelectionChrome(currentRect, ctx: ctx)
            }
            // Crosshair + magnifier loupe guide the cursor during selection. The
            // full-screen crosshair is redundant with the selection rect mid-drag.
            if !isDragging { drawCrosshair(at: mouseLocation, ctx: ctx) }
            drawLoupe(at: mouseLocation, ctx: ctx)
```

Replace with:

```swift
        case .region:
            if !currentRect.isEmpty {
                // Punch the selection back to full brightness by re-drawing the
                // bright frozen image clipped to the selection only.
                ctx.saveGState()
                ctx.clip(to: currentRect)
                ctx.draw(frozen, in: bounds)
                ctx.restoreGState()
                drawSelectionChrome(currentRect, ctx: ctx)
                drawHandles(currentRect, ctx: ctx)
            }
            // The crosshair guides a fresh drag; the loupe aids precise creating
            // and resizing. Neither shows while idle or moving a pre-shown rect.
            if isCreatingDrag { drawCrosshair(at: mouseLocation, ctx: ctx) }
            if showsLoupe { drawLoupe(at: mouseLocation, ctx: ctx) }
```

Add a `drawHandles` method next to `drawSelectionChrome`:

```swift
    private func drawHandles(_ rect: CGRect, ctx: CGContext) {
        let rects = SelectionGeometry.handleRects(for: rect, handleSize: Self.handleVisualSize)
        for handle in SelectionHandle.allCases {
            guard let hr = rects[handle] else { continue }
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(hr)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(hr)
        }
    }
```

- [ ] **Step 2: Set the cursor from the hovered part**

Replace the body of `mouseMoved(with:)` with:

```swift
    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        mouseLocation = local
        if mode == .window {
            hoveredWindow = WindowEnumerator.window(under: cgGlobalPoint(globalPoint(local)), in: windows)
        } else if mode == .region, !currentRect.isEmpty {
            updateCursor(for: SelectionGeometry.hitTest(local, in: currentRect, handleSize: Self.handleHitSize))
        }
        needsDisplay = true
    }

    /// Best-effort resize/move cursors. AppKit has no public diagonal resize
    /// cursor, so corners fall back to the crosshair.
    private func updateCursor(for hit: SelectionHit) {
        switch hit {
        case .handle(.left), .handle(.right): NSCursor.resizeLeftRight.set()
        case .handle(.top), .handle(.bottom): NSCursor.resizeUpDown.set()
        case .handle: NSCursor.crosshair.set()
        case .inside: NSCursor.openHand.set()
        case .outside: NSCursor.crosshair.set()
        }
    }
```

- [ ] **Step 3: Stop forcing the crosshair cursor rect over the whole view**

`resetCursorRects` currently pins the crosshair across `bounds`, which fights the
per-part cursor. Replace its body with an empty implementation so `mouseMoved`
owns the cursor:

```swift
    override func resetCursorRects() {
        // Cursor is managed in `mouseMoved` (crosshair vs. resize vs. move).
    }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): draw selection handles and hover cursors"
```

---

### Task 7: Coordinator computes the initial rect and persists on commit

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift:21-88,284-289`

- [ ] **Step 1: Replace `captureRegion` and add the initial-rect helper**

Replace `captureRegion(delay:)` (currently lines ~74-88) with:

```swift
    private func captureRegion(delay: Int) {
        let (targets, frozen) = Self.resolveAllDisplays()
        guard !targets.isEmpty else { finish(); return }
        let initialRect = Self.initialSelectionRect(targets: targets, settings: settings)
        selectionOverlay.present(targets: targets, mode: .region, frozen: frozen, initialRect: initialRect) { [weak self] result in
            guard let self else { return }
            guard case let .region(cgImage, rect) = result else { self.finish(); return }
            self.settings.setLastRegionRect(rect)
            self.afterCountdown(delay) { [weak self] in
                self?.present(image: cgImage, anchor: rect)
                self?.finish()
            }
        }
    }

    /// The pre-shown selection rect (global AppKit coords): the persisted last
    /// rect when its center lies on a connected display, else a default rect
    /// centered on the display under the cursor (or the first display).
    @MainActor private static func initialSelectionRect(targets: [TargetDisplay], settings: CaptureSettings) -> CGRect {
        let displays = targets.map(\.frame)
        if let restored = SelectionGeometry.restoredRect(last: settings.lastRegionRect, displays: displays) {
            return restored
        }
        let mouse = NSEvent.mouseLocation
        let screen = targets.first(where: { $0.frame.contains(mouse) })?.frame ?? targets[0].frame
        return SelectionGeometry.defaultCenteredRect(in: screen, fraction: 0.5)
    }
```

- [ ] **Step 2: Remove the now-unused in-memory rect/flag and simplify `recapture`**

The persisted rect is always restored from settings, so both the in-memory
`lastRegionRect` and the `reuseLastRect` flag are dead.

Delete these two stored properties (lines ~22-27):

```swift
    /// The last committed region rect (global AppKit coordinates), pre-filled into
    /// the selection overlay on re-capture so the previous selection can be reused.
    private var lastRegionRect: CGRect = .zero
```

```swift
    /// Set for the next capture only, to reuse the previous selection rect.
    private var reuseLastRect = false
```

Replace `recapture()` (lines ~284-289) with:

```swift
    private func recapture() {
        // The previous region rect is restored automatically from settings.
        capture(lastRegionRequest ?? CaptureRequest(mode: .region))
    }
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!` (no "unused/undefined `reuseLastRect`" errors).

- [ ] **Step 4: Run the full test suite**

Run: `swift test 2>&1 | tail -15`
Expected: PASS (all targets green).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift
git commit -m "feat(capture): pre-show restored/default selection and persist it"
```

---

### Task 8: Manual verification

**Files:** none (verification only)

Phase 1 changes the interactive overlay, which unit tests cannot cover. Verify
the build runs and the interaction behaves before declaring Phase 1 done.

- [ ] **Step 1: Build and run**

Run: `swift build 2>&1 | tail -5` → `Build complete!`
Then run the app: `swift run AnyDoor` (requires Accessibility + Screen Recording
permission for the `swift run` identity).

- [ ] **Step 2: Verify the interaction checklist**

Trigger the screenshot menu item and confirm:
- A selection rectangle appears immediately (centered ~50% on first use).
- Dragging a corner/edge handle resizes; the opposite corner/edge stays put.
- Dragging inside the rectangle moves the whole rectangle; it clamps at screen edges.
- Dragging on empty area starts a fresh selection.
- The W×H label and 8 handles render; the loupe shows while creating/resizing.
- **Enter** captures the current selection (quick-access overlay appears); **Esc** cancels.
- Re-trigger: the previous selection is pre-shown. Quit and relaunch, re-trigger:
  the previous selection is still pre-shown (cross-launch persistence).
- On a multi-display setup, the selection and Enter act on the display holding the rect.

- [ ] **Step 3: Update the changelog**

Add an entry under `## [Unreleased]` in `CHANGELOG.md` (create the heading if the
section has no list yet):

```markdown
### Added
- Region screenshot now opens with a pre-shown, mouse-adjustable selection
  (resize handles + move + new-drag), restored from the last selection across
  launches or centered by default.
```

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(capture): note pre-shown adjustable region selection"
```

---

## Self-Review

- **Spec coverage (Phase 1 rows only):** pre-shown rect (Tasks 5, 7) ✓; 8 handles
  + move + new-drag (Tasks 1, 5, 6) ✓; default centered 50% (Tasks 2, 7) ✓;
  cross-launch persistence (Task 3, 7) ✓; `SelectionGeometry` handle functions +
  unit tests (Tasks 1, 2) ✓; region-only / Enter-confirm (Task 5) ✓. Toolbar,
  window/fullscreen/scrolling/recording switching, and removing
  `CaptureModeBarWindow` are Phase 2/3 — intentionally absent.
- **Placeholder scan:** every code step shows full code; every run step shows an
  exact command and expected result. No TBD/TODO.
- **Type consistency:** `SelectionHandle`, `SelectionHit`, `handleRects`,
  `hitTest`, `resizing`, `defaultCenteredRect`, `restoredRect`,
  `CaptureSettings.lastRegionRect` / `setLastRegionRect`, `DragMode`,
  `initialSelectionRect` are used with identical signatures across tasks. The view
  reuses the existing `SelectionGeometry.moved` / `clamped` / `normalizedRect` /
  `isTooSmall` / `minimumEdge` for move/new-drag.
