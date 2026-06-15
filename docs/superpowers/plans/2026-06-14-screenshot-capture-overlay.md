# Screenshot Capture Engine + Quick Access Overlay (Phase 0) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a unified screenshot capture engine (region / window / fullscreen / timer) with a custom freeze-screen selection overlay and a quick-access overlay that follows the captured region, offering copy / save / edit-entry / pin / OCR / drag / re-capture / delete.

**Architecture:** A `@MainActor CaptureCoordinator` orchestrates each capture: it resolves the mode, runs a custom `SelectionOverlayWindow` (which captures a full-screen still up front — giving freeze-screen + magnifier for free — and crops it for region captures), grabs window captures via an `actor ScreenCaptureService` (ScreenCaptureKit), applies an output policy (auto-save + auto-copy + clipboard history), and presents a `CaptureOverlayWindow` next to the region. Five thin `ActionProvider`s route the existing builtin/hotkey/command-palette paths into the coordinator. Pure logic (geometry, filename templating, overlay placement, mode-bar policy, window hit-testing) is factored into testable helpers.

**Tech Stack:** Swift 6 (strict concurrency, `.v6` mode), macOS 14+, ScreenCaptureKit (`SCShareableContent` / `SCScreenshotManager`), AppKit `NSPanel`, SwiftUI `NSHostingView`, Vision (existing `TextRecognizer`), SwiftData (existing `ClipboardHistoryStore`), XCTest.

**Conventions:** All code comments in English. UI strings are Chinese, added via `L10n.Key` + `Localizable.xcstrings`. Commit messages follow Conventional Commits, scope `capture`. Build with `swift build`; run tests with `swift test`.

---

## File Structure

**New files:**
- `Sources/AnyDoor/Services/Capture/CaptureTypes.swift` — value types: `CaptureMode`, `CaptureRequest`, `CaptureTarget`, `SelectionResult`.
- `Sources/AnyDoor/Services/Capture/CaptureSettings.swift` — UserDefaults-backed config singleton.
- `Sources/AnyDoor/Services/Capture/CaptureFilename.swift` — pure filename templating + collision resolution.
- `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift` — pure rect math + display hit-testing.
- `Sources/AnyDoor/Services/Capture/WindowEnumerator.swift` — on-screen window list + pure hit-test.
- `Sources/AnyDoor/Services/Capture/OverlayPlacement.swift` — pure overlay frame placement + edge avoidance.
- `Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift` — pure mode-bar key/index → mode mapping.
- `Sources/AnyDoor/Services/Capture/ScreenCaptureService.swift` — `actor`, ScreenCaptureKit stills.
- `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift` — `@MainActor` orchestrator.
- `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` — freeze-screen selection UI (region + window pick + magnifier).
- `Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift` — All-In-One mode bar.
- `Sources/AnyDoor/Views/Capture/CaptureOverlayWindow.swift` — quick access overlay.
- `Sources/AnyDoor/Views/Capture/PinnedImageWindow.swift` — pin-to-screen floating window.
- `Sources/AnyDoor/Views/Capture/AnnotationEditorWindow.swift` — placeholder editor window (Phase 1 fills it).
- `Sources/AnyDoor/Services/Providers/CaptureProviders.swift` — five `ActionProvider`s.
- `Tests/AnyDoorTests/CaptureFilenameTests.swift`
- `Tests/AnyDoorTests/SelectionGeometryTests.swift`
- `Tests/AnyDoorTests/WindowEnumeratorTests.swift`
- `Tests/AnyDoorTests/OverlayPlacementTests.swift`
- `Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift`
- `Tests/AnyDoorTests/CaptureSettingsTests.swift`

**Modified files:**
- `Sources/AnyDoor/Models/BuiltinItem.swift` — repurpose `.screenshot` to region capture; add `.captureWindow`, `.captureFullscreen`, `.captureTimer`, `.captureModeBar`.
- `Sources/AnyDoor/Utilities/L10n.swift` — new keys.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — new translations.
- `Sources/AnyDoor/Services/SyncSettingsRegistry.swift` — capture setting entries.
- `Sources/AnyDoor/Services/CommandPaletteOptions.swift` — timer delay submenu (`.captureTimer` option parent).
- `Sources/AnyDoor/Services/ClipboardHistoryStore.swift` — add `recordScreenshot(pngData:)`.
- `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift` — delete (replaced by `CaptureRegionProvider`).
- `Sources/AnyDoor/AppDelegate.swift` — swap `ScreenshotProvider()` for the five new providers; bootstrap `CaptureCoordinator`.

---

## Task 1: Capture value types

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureTypes.swift`

- [ ] **Step 1: Write the value types**

```swift
import CoreGraphics
import Foundation

/// The three primitive capture modes. `timer` is not a mode — it is any of these
/// run after a countdown (see `CaptureRequest.delay`).
enum CaptureMode: String, Sendable, CaseIterable {
    case region
    case window
    case fullscreen
}

/// A capture the coordinator should perform. `delay` is the self-timer countdown
/// in seconds (0 = immediate). For `region`/`window`, selection happens first,
/// then the countdown, then the grab — so the user can arrange transient UI.
struct CaptureRequest: Sendable, Equatable {
    let mode: CaptureMode
    let delay: Int

    init(mode: CaptureMode, delay: Int = 0) {
        self.mode = mode
        self.delay = max(0, delay)
    }
}

/// A resolved capture source handed to `ScreenCaptureService`.
enum CaptureTarget: Sendable, Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    /// A sub-rectangle of a display, in that display's local top-left points.
    case rect(CGRect, display: CGDirectDisplayID)
}

/// What the selection overlay returns to the coordinator.
enum SelectionResult: Sendable {
    /// Region selected. The overlay already cropped its frozen backing still, so
    /// the image is returned directly (no second capture needed). `rect` is in
    /// global AppKit screen coordinates (bottom-left origin) for overlay placement.
    case region(image: CGImage, rect: CGRect)
    /// A window was picked; the coordinator captures it crisply via ScreenCaptureKit.
    /// `frame` is the window's global AppKit screen frame for overlay placement.
    case window(id: CGWindowID, frame: CGRect)
    case cancelled
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (the file has no dependencies yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureTypes.swift
git commit -m "feat(capture): add capture value types"
```

---

## Task 2: Filename templating helper (pure, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureFilename.swift`
- Test: `Tests/AnyDoorTests/CaptureFilenameTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnyDoor

final class CaptureFilenameTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return utcCalendar().date(from: c)!
    }

    func testExpandsTokens() {
        let name = CaptureFilename.make(
            template: "Screenshot YYYY-MM-DD at HH.mm.ss",
            date: date(2026, 6, 14, 9, 5, 3),
            calendar: utcCalendar()
        )
        XCTAssertEqual(name, "Screenshot 2026-06-14 at 09.05.03")
    }

    func testStripsPathSeparators() {
        let name = CaptureFilename.make(
            template: "a/b:c",
            date: date(2026, 1, 1, 0, 0, 0),
            calendar: utcCalendar()
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testResolveReturnsBaseWhenFree() {
        let resolved = CaptureFilename.resolve(base: "Shot", ext: "png") { _ in false }
        XCTAssertEqual(resolved, "Shot.png")
    }

    func testResolveSuffixesOnCollision() {
        let taken: Set<String> = ["Shot.png", "Shot 2.png"]
        let resolved = CaptureFilename.resolve(base: "Shot", ext: "png") { taken.contains($0) }
        XCTAssertEqual(resolved, "Shot 3.png")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CaptureFilenameTests`
Expected: FAIL — `CaptureFilename` is undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure helpers for turning a naming template + date into a filesystem-safe file
/// name, and for de-duplicating against existing files. No I/O — callers inject
/// the existence check so this stays unit-testable.
enum CaptureFilename {
    /// Expands `YYYY MM DD HH mm ss` tokens (longest-first so `MM`/`mm` are
    /// unambiguous), then strips characters illegal in a file name.
    static func make(template: String, date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ width: Int) -> String {
            String(format: "%0\(width)d", v ?? 0)
        }
        var out = template
        out = out.replacingOccurrences(of: "YYYY", with: pad(c.year, 4))
        out = out.replacingOccurrences(of: "MM", with: pad(c.month, 2))
        out = out.replacingOccurrences(of: "DD", with: pad(c.day, 2))
        out = out.replacingOccurrences(of: "HH", with: pad(c.hour, 2))
        out = out.replacingOccurrences(of: "mm", with: pad(c.minute, 2))
        out = out.replacingOccurrences(of: "ss", with: pad(c.second, 2))
        // Strip path separators and other illegal filename characters.
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return out.components(separatedBy: illegal).joined()
    }

    /// Returns `"<base>.<ext>"`, or `"<base> N.<ext>"` with the smallest N >= 2
    /// that is free per `exists`.
    static func resolve(base: String, ext: String, exists: (String) -> Bool) -> String {
        let first = "\(base).\(ext)"
        if !exists(first) { return first }
        var n = 2
        while exists("\(base) \(n).\(ext)") { n += 1 }
        return "\(base) \(n).\(ext)"
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter CaptureFilenameTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureFilename.swift Tests/AnyDoorTests/CaptureFilenameTests.swift
git commit -m "feat(capture): add filename templating helper"
```

---

## Task 3: Selection geometry helpers (pure, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/SelectionGeometry.swift`
- Test: `Tests/AnyDoorTests/SelectionGeometryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

final class SelectionGeometryTests: XCTestCase {
    func testNormalizedRectFromAnyDragDirection() {
        let r = SelectionGeometry.normalizedRect(from: CGPoint(x: 100, y: 80), to: CGPoint(x: 40, y: 120))
        XCTAssertEqual(r, CGRect(x: 40, y: 80, width: 60, height: 40))
    }

    func testClampedToBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let r = SelectionGeometry.clamped(CGRect(x: -10, y: 150, width: 60, height: 100), to: bounds)
        XCTAssertEqual(r, CGRect(x: 0, y: 150, width: 50, height: 50))
    }

    func testFormatDimensions() {
        XCTAssertEqual(SelectionGeometry.formatDimensions(CGSize(width: 12.6, height: 40.2)), "13 × 40")
    }

    func testRectIsEmptyBelowMinimum() {
        XCTAssertTrue(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 3, height: 50)))
        XCTAssertFalse(SelectionGeometry.isTooSmall(CGRect(x: 0, y: 0, width: 6, height: 6)))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SelectionGeometryTests`
Expected: FAIL — `SelectionGeometry` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import CoreGraphics
import Foundation

/// Pure geometry used by the selection overlay. No AppKit, no I/O.
enum SelectionGeometry {
    /// Minimum selectable edge length in points; smaller drags are treated as a
    /// stray click (cancellation).
    static let minimumEdge: CGFloat = 5

    /// Builds a normalized rect from two drag endpoints regardless of direction.
    static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }

    /// Intersects `rect` with `bounds` so a selection can never leave the screen.
    static func clamped(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        rect.intersection(bounds)
    }

    /// "W × H" using rounded integer points.
    static func formatDimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    static func isTooSmall(_ rect: CGRect) -> Bool {
        rect.width < minimumEdge || rect.height < minimumEdge
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter SelectionGeometryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/SelectionGeometry.swift Tests/AnyDoorTests/SelectionGeometryTests.swift
git commit -m "feat(capture): add selection geometry helpers"
```

---

## Task 4: Window enumeration + hit-test (TDD for the pure part)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/WindowEnumerator.swift`
- Test: `Tests/AnyDoorTests/WindowEnumeratorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

final class WindowEnumeratorTests: XCTestCase {
    func testTopmostWindowUnderPointWins() {
        // Listed front-to-back (index 0 == frontmost), matching CGWindowList order.
        let windows = [
            CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100)),
            CapturableWindow(id: 2, frame: CGRect(x: 0, y: 0, width: 200, height: 200)),
        ]
        let hit = WindowEnumerator.window(under: CGPoint(x: 50, y: 50), in: windows)
        XCTAssertEqual(hit?.id, 1)
    }

    func testPointOutsideAllReturnsNil() {
        let windows = [CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        XCTAssertNil(WindowEnumerator.window(under: CGPoint(x: 99, y: 99), in: windows))
    }

    func testFallsThroughToLowerWindow() {
        let windows = [
            CapturableWindow(id: 1, frame: CGRect(x: 0, y: 0, width: 50, height: 50)),
            CapturableWindow(id: 2, frame: CGRect(x: 100, y: 100, width: 50, height: 50)),
        ]
        let hit = WindowEnumerator.window(under: CGPoint(x: 120, y: 120), in: windows)
        XCTAssertEqual(hit?.id, 2)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter WindowEnumeratorTests`
Expected: FAIL — `CapturableWindow` / `WindowEnumerator` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import CoreGraphics
import Foundation

/// An on-screen window candidate for window-mode capture. `frame` is in global
/// CoreGraphics coordinates (top-left origin), as returned by CGWindowList.
struct CapturableWindow: Sendable, Equatable {
    let id: CGWindowID
    let frame: CGRect
}

enum WindowEnumerator {
    /// The frontmost window whose frame contains `point`. `windows` must be ordered
    /// front-to-back (CGWindowList's natural order). Pure — unit-testable.
    static func window(under point: CGPoint, in windows: [CapturableWindow]) -> CapturableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    /// Live on-screen windows at layer 0 (normal app windows), front-to-back.
    /// Excludes the desktop, menu bar, and our own overlay windows by layer.
    static func onScreenWindows() -> [CapturableWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.compactMap { info in
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return CapturableWindow(id: CGWindowID(number), frame: bounds)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter WindowEnumeratorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/WindowEnumerator.swift Tests/AnyDoorTests/WindowEnumeratorTests.swift
git commit -m "feat(capture): add window enumeration and hit-test"
```

---

## Task 5: Overlay placement helper (pure, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/OverlayPlacement.swift`
- Test: `Tests/AnyDoorTests/OverlayPlacementTests.swift`

Coordinate space: global AppKit screen coordinates (bottom-left origin, y up).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

final class OverlayPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let size = CGSize(width: 200, height: 80)

    func testPlacesBelowRegionByDefault() {
        // Region high on screen -> overlay sits just below it (lower y in AppKit).
        let region = CGRect(x: 400, y: 500, width: 200, height: 150)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertEqual(frame.maxY, region.minY - 12, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    func testFlipsAboveWhenNoRoomBelow() {
        // Region near the bottom -> no room below, overlay goes above it.
        let region = CGRect(x: 400, y: 0, width: 200, height: 60)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertEqual(frame.minY, region.maxY + 12, accuracy: 0.001)
        XCTAssertTrue(screen.contains(frame))
    }

    func testFallbackBottomRightWhenNoRegion() {
        let frame = OverlayPlacement.fallbackFrame(overlaySize: size, onScreen: screen, margin: 16)
        XCTAssertEqual(frame.maxX, screen.maxX - 16, accuracy: 0.001)
        XCTAssertEqual(frame.minY, screen.minY + 16, accuracy: 0.001)
    }

    func testClampsHorizontallyIntoScreen() {
        let region = CGRect(x: 950, y: 400, width: 40, height: 40)
        let frame = OverlayPlacement.frame(forRegion: region, overlaySize: size, onScreen: screen, gap: 12)
        XCTAssertTrue(screen.contains(frame))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter OverlayPlacementTests`
Expected: FAIL — `OverlayPlacement` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import CoreGraphics
import Foundation

/// Pure placement of the quick-access overlay relative to a captured region.
/// Global AppKit screen coordinates (bottom-left origin). No AppKit dependency.
enum OverlayPlacement {
    /// Centers the overlay horizontally under the region (flipping above if there
    /// is no room below), then clamps the whole frame inside the screen.
    static func frame(forRegion region: CGRect, overlaySize: CGSize, onScreen screen: CGRect, gap: CGFloat) -> CGRect {
        let x = region.midX - overlaySize.width / 2
        // Prefer below the region (smaller y). If it would clip the bottom, flip above.
        var y = region.minY - gap - overlaySize.height
        if y < screen.minY {
            y = region.maxY + gap
        }
        let proposed = CGRect(x: x, y: y, width: overlaySize.width, height: overlaySize.height)
        return clampInside(proposed, screen: screen)
    }

    /// Bottom-right of the screen — used for fullscreen/window captures with no
    /// meaningful region anchor.
    static func fallbackFrame(overlaySize: CGSize, onScreen screen: CGRect, margin: CGFloat) -> CGRect {
        CGRect(
            x: screen.maxX - margin - overlaySize.width,
            y: screen.minY + margin,
            width: overlaySize.width,
            height: overlaySize.height
        )
    }

    private static func clampInside(_ rect: CGRect, screen: CGRect) -> CGRect {
        var r = rect
        if r.maxX > screen.maxX { r.origin.x = screen.maxX - r.width }
        if r.minX < screen.minX { r.origin.x = screen.minX }
        if r.maxY > screen.maxY { r.origin.y = screen.maxY - r.height }
        if r.minY < screen.minY { r.origin.y = screen.minY }
        return r
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter OverlayPlacementTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/OverlayPlacement.swift Tests/AnyDoorTests/OverlayPlacementTests.swift
git commit -m "feat(capture): add quick-access overlay placement helper"
```

---

## Task 6: Mode-bar selection policy (pure, TDD)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift`
- Test: `Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnyDoor

final class CaptureModeBarPolicyTests: XCTestCase {
    func testDigitKeysMapToModes() {
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 1), .region)
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 2), .window)
        XCTAssertEqual(CaptureModeBarPolicy.mode(forDigit: 3), .fullscreen)
        XCTAssertNil(CaptureModeBarPolicy.mode(forDigit: 9))
    }

    func testTimerDigitMapsToTimer() {
        XCTAssertTrue(CaptureModeBarPolicy.isTimerDigit(4))
        XCTAssertFalse(CaptureModeBarPolicy.isTimerDigit(1))
    }

    func testOrderedModesForRendering() {
        XCTAssertEqual(CaptureModeBarPolicy.orderedModes, [.region, .window, .fullscreen])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CaptureModeBarPolicyTests`
Expected: FAIL — `CaptureModeBarPolicy` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Pure mapping from mode-bar affordances (digit keys, render order) to modes.
/// The bar renders region/window/fullscreen/timer; recording/scrolling are shown
/// disabled and are NOT produced here.
enum CaptureModeBarPolicy {
    static let orderedModes: [CaptureMode] = [.region, .window, .fullscreen]

    /// Digit 1/2/3 select the ordered modes; 4 is reserved for timer.
    static func mode(forDigit digit: Int) -> CaptureMode? {
        let index = digit - 1
        guard orderedModes.indices.contains(index) else { return nil }
        return orderedModes[index]
    }

    static func isTimerDigit(_ digit: Int) -> Bool { digit == 4 }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter CaptureModeBarPolicyTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift
git commit -m "feat(capture): add mode-bar selection policy"
```

---

## Task 7: Capture settings (UserDefaults, TDD on defaults/IO)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureSettings.swift`
- Test: `Tests/AnyDoorTests/CaptureSettingsTests.swift`
- Modify: `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnyDoor

final class CaptureSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "capture.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsWhenUnset() {
        let s = CaptureSettings(defaults: makeDefaults())
        XCTAssertEqual(s.namingTemplate, "Screenshot YYYY-MM-DD at HH.mm.ss")
        XCTAssertTrue(s.autoCopy)
        XCTAssertTrue(s.autoSave)
        XCTAssertEqual(s.delaySeconds, 5)
        XCTAssertEqual(s.overlayTimeout, 8)
    }

    func testSettersPersist() {
        let d = makeDefaults()
        let s = CaptureSettings(defaults: d)
        s.setAutoCopy(false)
        s.setDelaySeconds(10)
        let reloaded = CaptureSettings(defaults: d)
        XCTAssertFalse(reloaded.autoCopy)
        XCTAssertEqual(reloaded.delaySeconds, 10)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter CaptureSettingsTests`
Expected: FAIL — `CaptureSettings` undefined.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// UserDefaults-backed capture configuration. Mirrors the HyperKeyService pattern
/// (explicit setters that write through). `@MainActor @Observable` so SwiftUI
/// settings views can bind to it later.
@MainActor
@Observable
final class CaptureSettings {
    static let shared = CaptureSettings()

    static let saveDirectoryKey = "capture.saveDirectory"
    static let namingTemplateKey = "capture.namingTemplate"
    static let autoCopyKey = "capture.autoCopy"
    static let autoSaveKey = "capture.autoSave"
    static let delaySecondsKey = "capture.delaySeconds"
    static let overlayTimeoutKey = "capture.overlayTimeout"

    static let defaultNamingTemplate = "Screenshot YYYY-MM-DD at HH.mm.ss"

    private let defaults: UserDefaults

    private(set) var saveDirectory: URL
    private(set) var namingTemplate: String
    private(set) var autoCopy: Bool
    private(set) var autoSave: Bool
    private(set) var delaySeconds: Int
    private(set) var overlayTimeout: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent("Pictures/AnyDoor", isDirectory: true)
        if let path = defaults.string(forKey: Self.saveDirectoryKey), !path.isEmpty {
            self.saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            self.saveDirectory = defaultDir
        }
        self.namingTemplate = defaults.string(forKey: Self.namingTemplateKey) ?? Self.defaultNamingTemplate
        self.autoCopy = defaults.object(forKey: Self.autoCopyKey) as? Bool ?? true
        self.autoSave = defaults.object(forKey: Self.autoSaveKey) as? Bool ?? true
        self.delaySeconds = defaults.object(forKey: Self.delaySecondsKey) as? Int ?? 5
        self.overlayTimeout = defaults.object(forKey: Self.overlayTimeoutKey) as? Int ?? 8
    }

    func setSaveDirectory(_ url: URL) {
        saveDirectory = url
        defaults.set(url.path, forKey: Self.saveDirectoryKey)
    }

    func setNamingTemplate(_ value: String) {
        namingTemplate = value
        defaults.set(value, forKey: Self.namingTemplateKey)
    }

    func setAutoCopy(_ value: Bool) {
        autoCopy = value
        defaults.set(value, forKey: Self.autoCopyKey)
    }

    func setAutoSave(_ value: Bool) {
        autoSave = value
        defaults.set(value, forKey: Self.autoSaveKey)
    }

    func setDelaySeconds(_ value: Int) {
        delaySeconds = value
        defaults.set(value, forKey: Self.delaySecondsKey)
    }

    func setOverlayTimeout(_ value: Int) {
        overlayTimeout = value
        defaults.set(value, forKey: Self.overlayTimeoutKey)
    }

    /// Re-read after a config import (parallels HyperKeyService.reloadFromDefaults).
    func reloadFromDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let defaultDir = home.appendingPathComponent("Pictures/AnyDoor", isDirectory: true)
        if let path = defaults.string(forKey: Self.saveDirectoryKey), !path.isEmpty {
            saveDirectory = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            saveDirectory = defaultDir
        }
        namingTemplate = defaults.string(forKey: Self.namingTemplateKey) ?? Self.defaultNamingTemplate
        autoCopy = defaults.object(forKey: Self.autoCopyKey) as? Bool ?? true
        autoSave = defaults.object(forKey: Self.autoSaveKey) as? Bool ?? true
        delaySeconds = defaults.object(forKey: Self.delaySecondsKey) as? Int ?? 5
        overlayTimeout = defaults.object(forKey: Self.overlayTimeoutKey) as? Int ?? 8
    }
}
```

- [ ] **Step 4: Register sync entries**

In `Sources/AnyDoor/Services/SyncSettingsRegistry.swift`, add to the `entries` array (after the `pickColor.format` entry):

```swift
Entry(key: "capture.saveDirectory", type: .string),
Entry(key: "capture.namingTemplate", type: .string),
Entry(key: "capture.autoCopy", type: .bool),
Entry(key: "capture.autoSave", type: .bool),
Entry(key: "capture.delaySeconds", type: .int),
Entry(key: "capture.overlayTimeout", type: .int),
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter CaptureSettingsTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureSettings.swift Tests/AnyDoorTests/CaptureSettingsTests.swift Sources/AnyDoor/Services/SyncSettingsRegistry.swift
git commit -m "feat(capture): add UserDefaults-backed capture settings"
```

---

## Task 8: ScreenCaptureService (ScreenCaptureKit, impl + manual)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/ScreenCaptureService.swift`

- [ ] **Step 1: Write the implementation**

```swift
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Errors from the capture engine.
enum CaptureError: Error {
    case permissionDenied
    case noShareableContent
    case targetNotFound
    case captureFailed
}

/// Serializes ScreenCaptureKit still captures (macOS 14+). All grabs go through
/// one actor so concurrent capture requests can't race the shared SCK machinery.
actor ScreenCaptureService {
    static let shared = ScreenCaptureService()

    /// Full still of a display.
    func captureDisplay(_ displayID: CGDirectDisplayID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID })
            ?? content.displays.first else {
            throw CaptureError.targetNotFound
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        config.showsCursor = false
        return try await capture(filter: filter, config: config)
    }

    /// Crisp capture of a single window, preserving transparency and shadow.
    func captureWindow(_ windowID: CGWindowID) async throws -> CGImage {
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.targetNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = window.frame.width > 0 ? 2 : 1 // backing scale is applied by SCK; request native size
        config.width = Int(window.frame.width) * scale
        config.height = Int(window.frame.height) * scale
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = false
        return try await capture(filter: filter, config: config)
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            throw CaptureError.permissionDenied
        }
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noShareableContent
        }
    }

    private func capture(filter: SCContentFilter, config: SCStreamConfiguration) async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.captureFailed
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds. If the compiler reports `SCScreenshotManager` availability, confirm the deployment target is macOS 14 (it is, per `CLAUDE.md`).

- [ ] **Step 3: Manual verification note**

Window capture coordinate/scale correctness is verified end-to-end in Task 14 (the coordinator wires real captures). No standalone manual step here.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScreenCaptureService.swift
git commit -m "feat(capture): add ScreenCaptureKit still-capture service"
```

---

## Task 9: Localization keys + BuiltinItem cases

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`

- [ ] **Step 1: Add L10n keys**

In `Sources/AnyDoor/Utilities/L10n.swift`, add these cases to `enum Key` (group them near the existing `builtinScreenshot` case):

```swift
case builtinCaptureWindow = "builtin.captureWindow"
case builtinCaptureFullscreen = "builtin.captureFullscreen"
case builtinCaptureTimer = "builtin.captureTimer"
case builtinCaptureModeBar = "builtin.captureModeBar"
case captureDelaySeconds = "capture.delay.seconds"
case captureToastSaved = "capture.toast.saved"
case captureToastCopied = "capture.toast.copied"
case captureToastFailed = "capture.toast.failed"
case captureOverlayCopy = "capture.overlay.copy"
case captureOverlaySave = "capture.overlay.save"
case captureOverlayEdit = "capture.overlay.edit"
case captureOverlayPin = "capture.overlay.pin"
case captureOverlayOCR = "capture.overlay.ocr"
case captureOverlayRecapture = "capture.overlay.recapture"
case captureOverlayDelete = "capture.overlay.delete"
case captureModeBarRegion = "capture.modeBar.region"
case captureModeBarWindow = "capture.modeBar.window"
case captureModeBarFullscreen = "capture.modeBar.fullscreen"
case captureModeBarTimer = "capture.modeBar.timer"
case captureModeBarRecording = "capture.modeBar.recording"
case captureModeBarScrolling = "capture.modeBar.scrolling"
case captureEditorPlaceholder = "capture.editor.placeholder"
case captureWindowPickHint = "capture.window.pickHint"
```

- [ ] **Step 2: Add xcstrings translations**

In `Sources/AnyDoor/Resources/Localizable.xcstrings`, add a `strings` entry for each new key (matching the existing `builtin.screenshot` shape). Use these en / zh-Hans values:

| key | en | zh-Hans |
|---|---|---|
| `builtin.captureWindow` | Capture Window | 窗口截图 |
| `builtin.captureFullscreen` | Capture Fullscreen | 全屏截图 |
| `builtin.captureTimer` | Timed Capture | 定时截图 |
| `builtin.captureModeBar` | Capture Menu | 截图菜单 |
| `capture.delay.seconds` | %lld s | %lld 秒 |
| `capture.toast.saved` | Saved to %@ | 已保存到 %@ |
| `capture.toast.copied` | Copied to clipboard | 已复制到剪贴板 |
| `capture.toast.failed` | Capture failed | 截图失败 |
| `capture.overlay.copy` | Copy | 复制 |
| `capture.overlay.save` | Save | 保存 |
| `capture.overlay.edit` | Edit | 编辑 |
| `capture.overlay.pin` | Pin | 钉住 |
| `capture.overlay.ocr` | Extract Text | 提取文字 |
| `capture.overlay.recapture` | Re-capture | 重新截图 |
| `capture.overlay.delete` | Delete | 删除 |
| `capture.modeBar.region` | Region | 区域 |
| `capture.modeBar.window` | Window | 窗口 |
| `capture.modeBar.fullscreen` | Fullscreen | 全屏 |
| `capture.modeBar.timer` | Timer | 定时 |
| `capture.modeBar.recording` | Record (soon) | 录屏(即将推出) |
| `capture.modeBar.scrolling` | Scrolling (soon) | 滚动(即将推出) |
| `capture.editor.placeholder` | The annotation editor is coming soon. | 标注编辑器即将推出。 |
| `capture.window.pickHint` | Click a window to capture it · Esc to cancel | 点击窗口进行截图 · Esc 取消 |

Note `capture.delay.seconds`, `capture.toast.saved`, and `capture.toast.copied` use format specifiers (`%lld` / `%@`) — set `extractionState` to `manual` like the other manual entries.

- [ ] **Step 3: Repurpose `.screenshot` and add new BuiltinItem cases**

In `Sources/AnyDoor/Models/BuiltinItem.swift`:

Add the new cases to the enum (near `.screenshot`):
```swift
    case captureWindow
    case captureFullscreen
    case captureTimer
    case captureModeBar
```

In `kind` — add the four new cases to the `.action` list (same arm as `.screenshot`):
```swift
    case .lockScreen, .emptyTrash, .screenshot, .captureWindow, .captureFullscreen, .captureTimer, .captureModeBar, .clearClipboard, .ocr, .qrcode, .pickColor, /* ...keep the rest of the existing arm unchanged... */:
        return .action
```

In `titleKey`:
```swift
    case .captureWindow:     return .builtinCaptureWindow
    case .captureFullscreen: return .builtinCaptureFullscreen
    case .captureTimer:      return .builtinCaptureTimer
    case .captureModeBar:    return .builtinCaptureModeBar
```

In `symbol`:
```swift
    case .captureWindow:     return "macwindow"
    case .captureFullscreen: return "rectangle.dashed"
    case .captureTimer:      return "timer"
    case .captureModeBar:    return "camera.on.rectangle"
```

In `defaultOrder` (place them right after `.screenshot`'s 900):
```swift
    case .captureWindow:     return 905
    case .captureFullscreen: return 910
    case .captureTimer:      return 915
    case .captureModeBar:    return 920
```

In `historyKind` (all four produce screenshots):
```swift
    case .captureWindow, .captureFullscreen, .captureTimer: return .screenshot
```
(`.captureModeBar` is a menu, not a capture — leave it on the `default: return nil` arm.)

- [ ] **Step 4: Build and run the localization test**

Run: `swift build`
Then: `swift test --filter BuiltinItemLocalizationTests`
Expected: PASS. (This existing test asserts every `BuiltinItem.titleKey` resolves to a non-empty localized string, so it catches any missing xcstrings entry.)

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings Sources/AnyDoor/Models/BuiltinItem.swift
git commit -m "feat(capture): add capture builtins and localized strings"
```

---

## Task 10: Screenshot history recorder

**Files:**
- Modify: `Sources/AnyDoor/Services/ClipboardHistoryStore.swift`

- [ ] **Step 1: Add `recordScreenshot(pngData:)`**

Add this method next to `recordScreenshotFromPasteboard()` (mirrors its file-write + insert, but takes PNG bytes directly so the coordinator controls the source image):

```swift
/// Records a screenshot from in-memory PNG bytes (the capture pipeline already
/// holds the image, so it does not round-trip through the pasteboard). Mirrors
/// `recordScreenshotFromPasteboard()`.
func recordScreenshot(pngData: Data) async {
    guard let container = modelContainer else { return }
    do {
        let id = UUID()
        let directory = historyDirectoryProvider()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).png"
        try pngData.write(to: directory.appendingPathComponent(fileName), options: .atomic)

        let item = ClipboardHistoryItem(
            id: id,
            kind: .screenshot,
            fileName: fileName,
            previewTitle: "",
            previewSubtitle: nil,
            createdAt: now()
        )
        container.mainContext.insert(item)
        try container.mainContext.save()
        await pruneExpiredAndOverflow(force: true)
        await reload(kind: .screenshot)
    } catch {
        historyLogger.error("Failed to record screenshot history: \(error)")
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/ClipboardHistoryStore.swift
git commit -m "feat(capture): record screenshots from in-memory PNG data"
```

---

## Task 11: Selection overlay window (freeze-screen + region + window pick)

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift`

This is the most involved UI piece. It captures a frozen still of the target
display up front (freeze-screen + magnifier source), shows it full-screen, and
lets the user drag a region (cropped from the still) or, in window mode, click a
highlighted window (returns the window id for a crisp SCK capture).

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import CoreGraphics

/// Full-screen, non-activating selection overlay. On show it freezes the target
/// display (a single SCK still), draws it dimmed, and tracks a drag selection
/// (region mode) or a hovered-window pick (window mode). Region commit crops the
/// frozen still and returns it directly. Coordinates handed back are global AppKit
/// screen points (bottom-left origin).
@MainActor
final class SelectionOverlayWindow {
    private var panel: NSPanel?
    private var completion: ((SelectionResult) -> Void)?

    /// Presents the overlay on the screen under the mouse. `mode` is `.region` or
    /// `.window` (fullscreen never uses the overlay). Calls `completion` exactly
    /// once with the result, then tears down.
    func present(mode: CaptureMode, completion: @escaping (SelectionResult) -> Void) async {
        self.completion = completion
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen, let displayID = screen.displayID else {
            finish(.cancelled); return
        }

        // Freeze the display now: one still used both as backdrop and (region mode)
        // as the source we crop on commit. Window mode does a crisp SCK grab later.
        let frozen: CGImage
        do {
            frozen = try await ScreenCaptureService.shared.captureDisplay(displayID)
        } catch {
            finish(.cancelled); return
        }

        let p = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = SelectionOverlayView(
            mode: mode,
            screenFrame: screen.frame,
            backingScale: screen.backingScaleFactor,
            frozen: frozen
        )
        view.onRegion = { [weak self] image, rect in self?.finish(.region(image: image, rect: rect)) }
        view.onWindow = { [weak self] id, frame in self?.finish(.window(id: id, frame: frame)) }
        view.onCancel = { [weak self] in self?.finish(.cancelled) }
        p.contentView = view
        panel = p
        p.orderFrontRegardless()
        p.makeFirstResponder(view)
    }

    private func finish(_ result: SelectionResult) {
        panel?.orderOut(nil)
        panel = nil
        let c = completion
        completion = nil
        c?(result)
    }
}

/// The drawing + tracking view. Region mode: drag a rectangle; commit crops the
/// frozen still. Window mode: highlight the window under the cursor; click commits.
private final class SelectionOverlayView: NSView {
    enum Mode { case region, window }

    var onRegion: ((CGImage, CGRect) -> Void)?
    var onWindow: ((CGWindowID, CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private let mode: CaptureMode
    private let screenFrame: CGRect
    private let backingScale: CGFloat
    private let frozen: CGImage
    private let windows: [CapturableWindow]

    private var dragStart: CGPoint?
    private var currentRect: CGRect = .zero
    private var hoveredWindow: CapturableWindow?

    init(mode: CaptureMode, screenFrame: CGRect, backingScale: CGFloat, frozen: CGImage) {
        self.mode = mode
        self.screenFrame = screenFrame
        self.backingScale = backingScale
        self.frozen = frozen
        self.windows = mode == .window ? WindowEnumerator.onScreenWindows() : []
        super.init(frame: NSRect(origin: .zero, size: screenFrame.size))
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        NSCursor.crosshair.set()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Coordinate helpers

    /// Local view point (bottom-left origin) -> global AppKit screen point.
    private func globalPoint(_ local: NSPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + local.x, y: screenFrame.minY + local.y)
    }

    /// Global AppKit screen point (bottom-left) -> CoreGraphics global point (top-left).
    private func cgGlobalPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: totalHeightFlip() - p.y)
    }

    private func totalHeightFlip() -> CGFloat {
        // Flip around the union of all screens so CGWindowList top-left coords line up.
        (NSScreen.screens.map { $0.frame.maxY }.max() ?? screenFrame.maxY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Frozen backdrop.
        ctx.draw(frozen, in: bounds)
        // Dim.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(bounds)

        switch mode {
        case .region:
            if !currentRect.isEmpty {
                // Punch the selection back to full brightness.
                ctx.draw(frozen, in: regionImageDestRect(for: currentRect), byTiling: false)
                drawSelectionChrome(currentRect, ctx: ctx)
            }
        case .window:
            if let win = hoveredWindow {
                let local = localRect(forCGWindow: win.frame)
                ctx.draw(frozen, in: bounds.intersection(local).isNull ? local : local)
                drawSelectionChrome(local, ctx: ctx)
            }
        }
    }

    /// Where in the view to redraw the frozen image so the selection shows through.
    private func regionImageDestRect(for rect: CGRect) -> CGRect { bounds }

    private func drawSelectionChrome(_ rect: CGRect, ctx: CGContext) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(rect)
        // Dimension label.
        let label = SelectionGeometry.formatDimensions(rect.size) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        let bg = CGRect(x: rect.minX, y: rect.maxY + 4, width: size.width + 8, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fill(bg)
        label.draw(at: NSPoint(x: bg.minX + 4, y: bg.minY + 2), withAttributes: attrs)
    }

    /// CGWindow global frame (top-left) -> this view's local rect (bottom-left).
    private func localRect(forCGWindow frame: CGRect) -> CGRect {
        let flip = totalHeightFlip()
        let globalBottomLeftY = flip - frame.maxY
        return CGRect(
            x: frame.minX - screenFrame.minX,
            y: globalBottomLeftY - screenFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: Mouse / key tracking

    override func mouseDown(with event: NSEvent) {
        guard mode == .region else { return }
        dragStart = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = SelectionGeometry.clamped(SelectionGeometry.normalizedRect(from: start, to: p), to: bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .region:
            guard !SelectionGeometry.isTooSmall(currentRect) else { onCancel?(); return }
            commitRegion(currentRect)
        case .window:
            guard let win = hoveredWindow else { onCancel?(); return }
            let global = globalScreenFrame(forCGWindow: win.frame)
            onWindow?(win.id, global)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let local = convert(event.locationInWindow, from: nil)
        let cgPoint = cgGlobalPoint(globalPoint(local))
        hoveredWindow = WindowEnumerator.window(under: cgPoint, in: windows)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Esc
    }

    private func commitRegion(_ rect: CGRect) {
        // Crop the frozen still. View points -> pixel rect (top-left origin).
        let scale = backingScale
        let pixelRect = CGRect(
            x: rect.minX * scale,
            y: (bounds.height - rect.maxY) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        guard let cropped = frozen.cropping(to: pixelRect) else { onCancel?(); return }
        onRegion?(cropped, globalPoint(rect.origin).asRect(size: rect.size))
    }

    /// CGWindow global frame (top-left) -> global AppKit screen frame (bottom-left).
    private func globalScreenFrame(forCGWindow frame: CGRect) -> CGRect {
        let flip = totalHeightFlip()
        return CGRect(x: frame.minX, y: flip - frame.maxY, width: frame.width, height: frame.height)
    }
}

private extension CGPoint {
    func asRect(size: CGSize) -> CGRect { CGRect(origin: self, size: size) }
}

extension NSScreen {
    /// The screen whose frame contains the current mouse location.
    static var screenUnderMouse: NSScreen? {
        let loc = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(loc) }
    }

    /// The CoreGraphics display ID for this screen, if available.
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds. Resolve any compiler errors in the coordinate helpers before continuing.

- [ ] **Step 3: Manual verification note**

The overlay is exercised end-to-end in Task 14. Coordinate correctness (region crop alignment, window highlight position, multi-display) is verified there with `swift run AnyDoor`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): add freeze-screen selection overlay"
```

---

## Task 12: Pinned image window

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/PinnedImageWindow.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import SwiftUI

/// An always-on-top floating image for reference. Drag to move, adjust opacity,
/// toggle click-through, close. Each pin is its own window so several can coexist.
@MainActor
final class PinnedImageWindow {
    private static var windows: [PinnedImageWindow] = []

    private var panel: NSPanel?
    private var clickThrough = false

    static func show(image: NSImage, at screenFrame: CGRect) {
        let win = PinnedImageWindow()
        win.present(image: image, at: screenFrame)
        windows.append(win)
    }

    private func present(image: NSImage, at screenFrame: CGRect) {
        let maxDimension: CGFloat = 360
        let aspect = image.size.height / max(image.size.width, 1)
        let width = min(image.size.width, maxDimension)
        let size = CGSize(width: width, height: width * aspect)
        let origin = CGPoint(x: screenFrame.midX - size.width / 2, y: screenFrame.midY - size.height / 2)

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: PinnedImageView(
            image: image,
            onClose: { [weak self] in self?.close() },
            onOpacity: { [weak self] value in self?.panel?.alphaValue = value },
            onToggleClickThrough: { [weak self] in self?.toggleClickThrough() }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()
    }

    private func toggleClickThrough() {
        clickThrough.toggle()
        panel?.ignoresMouseEvents = clickThrough
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
        PinnedImageWindow.windows.removeAll { $0 === self }
    }
}

private struct PinnedImageView: View {
    let image: NSImage
    let onClose: () -> Void
    let onOpacity: (CGFloat) -> Void
    let onToggleClickThrough: () -> Void

    @State private var opacity: Double = 1
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
            if hovering {
                HStack(spacing: 8) {
                    Slider(value: $opacity, in: 0.2...1).frame(width: 80)
                        .onChange(of: opacity) { _, v in onOpacity(v) }
                    Button(action: onToggleClickThrough) { Image(systemName: "cursorarrow.slash") }
                        .buttonStyle(.plain)
                    Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .padding(6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/PinnedImageWindow.swift
git commit -m "feat(capture): add pin-to-screen floating window"
```

---

## Task 13: Placeholder annotation editor window

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/AnnotationEditorWindow.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import SwiftUI

/// Phase 0 placeholder. Opens a real (non-panel) window showing the captured
/// image with a "coming soon" banner. Phase 1 replaces the body with the editor.
/// Registered with `RegularWindowCoordinator` so the Dock icon appears while open.
@MainActor
final class AnnotationEditorWindow {
    static let shared = AnnotationEditorWindow()
    private var window: NSWindow?

    func show(image: NSImage) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let size = CGSize(width: min(image.size.width, 900), height: min(image.size.height, 700) + 44)
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = L(.builtinScreenshot)
        w.isRestorable = false
        w.center()
        w.contentView = NSHostingView(rootView: AnnotationEditorPlaceholderView(image: image))
        w.delegate = WindowCloseRelay.shared
        WindowCloseRelay.shared.onClose = { [weak self] in self?.window = nil }
        window = w
        RegularWindowCoordinator.shared.track(w)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Minimal NSWindowDelegate that nils the owning reference on close.
@MainActor
private final class WindowCloseRelay: NSObject, NSWindowDelegate {
    static let shared = WindowCloseRelay()
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

private struct AnnotationEditorPlaceholderView: View {
    let image: NSImage
    var body: some View {
        VStack(spacing: 0) {
            Text(L(.captureEditorPlaceholder))
                .font(.callout)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.yellow.opacity(0.25))
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/AnnotationEditorWindow.swift
git commit -m "feat(capture): add placeholder annotation editor window"
```

---

## Task 14: Quick-access overlay window

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/CaptureOverlayWindow.swift`

The overlay receives the captured image plus an optional saved-file URL and an
anchor rect, and exposes the action callbacks. It auto-dismisses after the
configured timeout unless hovered.

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import SwiftUI

/// Actions the overlay can request. The coordinator supplies the implementations.
@MainActor
struct CaptureOverlayActions {
    var copy: () -> Void
    var save: () -> Void
    var edit: () -> Void
    var pin: () -> Void
    var ocr: () -> Void
    var recapture: () -> Void
    var delete: () -> Void
}

/// Non-activating panel that shows the capture thumbnail (a drag source) plus an
/// action row. Positioned by `OverlayPlacement`. Auto-dismisses after a timeout
/// unless the pointer is inside it.
@MainActor
final class CaptureOverlayWindow {
    static let shared = CaptureOverlayWindow()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private static let overlaySize = CGSize(width: 280, height: 96)

    func present(image: NSImage, fileURL: URL?, anchor: CGRect?, timeout: Int, actions: CaptureOverlayActions) {
        close()
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let frame: CGRect
        if let anchor {
            frame = OverlayPlacement.frame(forRegion: anchor, overlaySize: Self.overlaySize, onScreen: screen.frame, gap: 12)
        } else {
            frame = OverlayPlacement.fallbackFrame(overlaySize: Self.overlaySize, onScreen: screen.frame, margin: 16)
        }

        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]

        let hosting = NSHostingView(rootView: CaptureOverlayView(
            image: image,
            fileURL: fileURL,
            actions: actions,
            onHoverChange: { [weak self] hovering in
                if hovering { self?.cancelDismiss() } else { self?.scheduleDismiss(after: timeout) }
            },
            onAction: { [weak self] in self?.close() }
        ))
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()
        scheduleDismiss(after: timeout)
    }

    private func scheduleDismiss(after seconds: Int) {
        cancelDismiss()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.close()
        }
    }

    private func cancelDismiss() {
        dismissTask?.cancel()
        dismissTask = nil
    }

    func close() {
        cancelDismiss()
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct CaptureOverlayView: View {
    let image: NSImage
    let fileURL: URL?
    let actions: CaptureOverlayActions
    let onHoverChange: (Bool) -> Void
    let onAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    button("doc.on.doc", L(.captureOverlayCopy), actions.copy)
                    button("square.and.arrow.down", L(.captureOverlaySave), actions.save)
                    button("pencil.tip.crop.circle", L(.captureOverlayEdit), actions.edit)
                    button("pin", L(.captureOverlayPin), actions.pin)
                }
                HStack(spacing: 10) {
                    button("text.viewfinder", L(.captureOverlayOCR), actions.ocr)
                    button("arrow.clockwise", L(.captureOverlayRecapture), actions.recapture)
                    button("trash", L(.captureOverlayDelete), actions.delete)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, height: 96)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onHover { onHoverChange($0) }
    }

    private var thumbnail: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onDrag { dragProvider() }
    }

    private func dragProvider() -> NSItemProvider {
        if let fileURL { return NSItemProvider(contentsOf: fileURL) ?? NSItemProvider(object: image) }
        return NSItemProvider(object: image)
    }

    private func button(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button {
            run()
            onAction()
        } label: {
            Image(systemName: symbol).font(.system(size: 14))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
```

Note: `NSItemProvider(object: image)` requires `NSImage` (which conforms to
`NSItemProviderWriting`). The save/delete buttons that should NOT auto-close (e.g.
save reveals in Finder but keeps the overlay) can be adjusted in the coordinator;
for Phase 0 every action closes the overlay for simplicity.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/CaptureOverlayWindow.swift
git commit -m "feat(capture): add quick-access overlay window"
```

---

## Task 15: Capture mode bar window

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import SwiftUI

/// All-In-One floating bar. Shows region/window/fullscreen/timer (enabled) and
/// recording/scrolling (disabled placeholders). Selecting a mode dismisses the
/// bar and calls back. Digit keys 1–4 and Esc are handled.
@MainActor
final class CaptureModeBarWindow {
    static let shared = CaptureModeBarWindow()
    private var panel: NSPanel?
    private var keyMonitor: Any?
    private var onPick: ((CaptureMode) -> Void)?
    private var onTimer: (() -> Void)?

    func present(onPick: @escaping (CaptureMode) -> Void, onTimer: @escaping () -> Void) {
        close()
        self.onPick = onPick
        self.onTimer = onTimer
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = CGSize(width: 460, height: 92)
        let origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 80)

        let p = NSPanel(
            contentRect: CGRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .screenSaver
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]

        let hosting = NSHostingView(rootView: CaptureModeBarView(
            onRegion: { [weak self] in self?.pick(.region) },
            onWindow: { [weak self] in self?.pick(.window) },
            onFullscreen: { [weak self] in self?.pick(.fullscreen) },
            onTimer: { [weak self] in self?.timer() }
        ))
        hosting.frame = CGRect(origin: .zero, size: size)
        p.contentView = hosting
        panel = p
        p.orderFrontRegardless()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated {
                if event.keyCode == 53 { self.close(); return nil } // Esc
                if let digit = Int(event.charactersIgnoringModifiers ?? "") {
                    if CaptureModeBarPolicy.isTimerDigit(digit) { self.timer(); return nil }
                    if let mode = CaptureModeBarPolicy.mode(forDigit: digit) { self.pick(mode); return nil }
                }
                return event
            }
        }
    }

    private func pick(_ mode: CaptureMode) {
        let cb = onPick
        close()
        cb?(mode)
    }

    private func timer() {
        let cb = onTimer
        close()
        cb?()
    }

    func close() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        panel?.orderOut(nil)
        panel = nil
        onPick = nil
        onTimer = nil
    }
}

private struct CaptureModeBarView: View {
    let onRegion: () -> Void
    let onWindow: () -> Void
    let onFullscreen: () -> Void
    let onTimer: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            item("rectangle.dashed", L(.captureModeBarRegion), onRegion)
            item("macwindow", L(.captureModeBarWindow), onWindow)
            item("rectangle.inset.filled", L(.captureModeBarFullscreen), onFullscreen)
            item("timer", L(.captureModeBarTimer), onTimer)
            Divider().frame(height: 40)
            disabledItem("record.circle", L(.captureModeBarRecording))
            disabledItem("arrow.down.to.line", L(.captureModeBarScrolling))
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func item(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(width: 56)
        }
        .buttonStyle(.plain)
    }

    private func disabledItem(_ symbol: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20))
            Text(title).font(.caption2)
        }
        .frame(width: 56)
        .foregroundStyle(.tertiary)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift
git commit -m "feat(capture): add All-In-One capture mode bar"
```

---

## Task 16: Capture coordinator (orchestrator)

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift`

- [ ] **Step 1: Write the implementation**

```swift
import AppKit
import Foundation

/// Orchestrates a single capture: resolve mode -> (selection / countdown / direct
/// grab) -> output policy (auto-save + auto-copy + history) -> quick-access overlay.
/// `@MainActor` because it drives windows and the pasteboard.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private let settings: CaptureSettings
    private let selectionOverlay = SelectionOverlayWindow()
    private var lastRegionRequest: CaptureRequest?
    private var inFlight = false

    init(settings: CaptureSettings = .shared) {
        self.settings = settings
    }

    /// Entry point used by every provider. Guards against re-entrancy.
    func capture(_ request: CaptureRequest) {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.run(request)
            self?.inFlight = false
        }
    }

    /// Opens the All-In-One mode bar; the chosen mode starts a capture.
    func presentModeBar() {
        CaptureModeBarWindow.shared.present(
            onPick: { [weak self] mode in self?.capture(CaptureRequest(mode: mode)) },
            onTimer: { [weak self] in
                guard let self else { return }
                self.capture(CaptureRequest(mode: .region, delay: self.settings.delaySeconds))
            }
        )
    }

    private func run(_ request: CaptureRequest) async {
        guard ScreenCapturePermission.isGranted || ScreenCapturePermission.request() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            return
        }

        let captured: (image: NSImage, anchor: CGRect?)?
        switch request.mode {
        case .region:
            captured = await captureRegion(delay: request.delay)
        case .window:
            captured = await captureWindow(delay: request.delay)
        case .fullscreen:
            captured = await captureFullscreen(delay: request.delay)
        }
        guard let captured else { return } // cancelled or failed (toast already shown on failure)
        lastRegionRequest = request
        await present(image: captured.image, anchor: captured.anchor)
    }

    // MARK: Mode handlers

    private func captureRegion(delay: Int) async -> (NSImage, CGRect?)? {
        let result = await withSelection(mode: .region)
        guard case let .region(cgImage, rect) = result else { return nil }
        await countdown(delay)
        return (NSImage(cgImage: cgImage, size: .zero), rect)
    }

    private func captureWindow(delay: Int) async -> (NSImage, CGRect?)? {
        let result = await withSelection(mode: .window)
        guard case let .window(id, frame) = result else { return nil }
        await countdown(delay)
        do {
            let cg = try await ScreenCaptureService.shared.captureWindow(id)
            return (NSImage(cgImage: cg, size: .zero), frame)
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func captureFullscreen(delay: Int) async -> (NSImage, CGRect?)? {
        await countdown(delay)
        let screen = NSScreen.screenUnderMouse ?? NSScreen.main
        guard let displayID = screen?.displayID else { return nil }
        do {
            let cg = try await ScreenCaptureService.shared.captureDisplay(displayID)
            return (NSImage(cgImage: cg, size: .zero), nil)
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func withSelection(mode: CaptureMode) async -> SelectionResult {
        await withCheckedContinuation { continuation in
            Task {
                await selectionOverlay.present(mode: mode) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private func countdown(_ seconds: Int) async {
        guard seconds > 0 else { return }
        // Minimal Phase 0 countdown: just wait. A visible countdown panel can be
        // added later without changing callers.
        try? await Task.sleep(for: .seconds(seconds))
    }

    // MARK: Output policy + overlay

    private func present(image: NSImage, anchor: CGRect?) async {
        guard let png = image.pngData() else {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return
        }

        var savedURL: URL?
        if settings.autoSave {
            savedURL = saveToDefaultDirectory(png: png)
        }
        if settings.autoCopy {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([image])
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
        }
        await ClipboardHistoryStore.shared.recordScreenshot(pngData: png)

        let actions = CaptureOverlayActions(
            copy: { [weak self] in self?.copyToPasteboard(image) },
            save: { [weak self] in self?.saveInteractive(png: png, existing: savedURL) },
            edit: { AnnotationEditorWindow.shared.show(image: image) },
            pin: {
                let screen = NSScreen.screenUnderMouse ?? NSScreen.main
                PinnedImageWindow.show(image: image, at: screen?.frame ?? .zero)
            },
            ocr: { [weak self] in self?.runOCR(image) },
            recapture: { [weak self] in self?.recapture() },
            delete: { savedURL.map { try? FileManager.default.removeItem(at: $0) } }
        )
        CaptureOverlayWindow.shared.present(
            image: image,
            fileURL: savedURL,
            anchor: anchor,
            timeout: settings.overlayTimeout,
            actions: actions
        )
    }

    private func saveToDefaultDirectory(png: Data) -> URL? {
        let dir = settings.saveDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let base = CaptureFilename.make(template: settings.namingTemplate, date: Date(), calendar: .current)
            let name = CaptureFilename.resolve(base: base, ext: "png") {
                FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
            }
            let url = dir.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            ToastPresenter.shared.show(.success(L(.captureToastSaved, dir.lastPathComponent)))
            return url
        } catch {
            ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            return nil
        }
    }

    private func saveInteractive(png: Data, existing: URL?) {
        if let existing {
            NSWorkspace.shared.activateFileViewerSelecting([existing])
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CaptureFilename.make(template: settings.namingTemplate, date: Date(), calendar: .current) + ".png"
        panel.allowedContentTypes = [.png]
        if panel.runModal() == .OK, let url = panel.url {
            try? png.write(to: url, options: .atomic)
        }
    }

    private func copyToPasteboard(_ image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
        ToastPresenter.shared.show(.success(L(.captureToastCopied)))
    }

    private func runOCR(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task {
            do {
                let lines = try await TextRecognizer.recognize(cg)
                let text = lines.joined(separator: "\n")
                guard !text.isEmpty else {
                    ToastPresenter.shared.show(.failure(L(.toastOcrNoText)))
                    return
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                ClipboardWatcher.shared?.noteSelfWrite(changeCount: pb.changeCount)
                await ClipboardHistoryStore.shared.recordText(kind: .ocr, text: text)
                ToastPresenter.shared.show(.success(L(.toastCopiedToClipboard)))
            } catch {
                ToastPresenter.shared.show(.failure(L(.toastRecognitionFailed)))
            }
        }
    }

    private func recapture() {
        if let last = lastRegionRequest {
            capture(last)
        } else {
            capture(CaptureRequest(mode: .region))
        }
    }
}

/// PNG encoding for an NSImage via its CGImage.
extension NSImage {
    func pngData() -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])
    }
}
```

Note `TextRecognizer.recognize(_:)` takes a `CGImage` (per `OCRProvider`). Confirm
the exact parameter type when wiring; adjust the `recognize` call if its signature
differs.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds. Fix any signature mismatches against `TextRecognizer` / `ToastPresenter` / `ClipboardWatcher`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift
git commit -m "feat(capture): add capture coordinator orchestrator"
```

---

## Task 17: Capture providers + AppDelegate wiring

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/CaptureProviders.swift`
- Delete: `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Write the providers**

```swift
import Foundation

/// Five thin action providers that route the builtin/hotkey/command-palette paths
/// into `CaptureCoordinator`. They report `.notRequired` and let the coordinator
/// gate Screen Recording permission inline (matching OCR/QR providers).
@MainActor
struct CaptureRegionProvider: ActionProvider {
    nonisolated let itemKey: BuiltinItem = .screenshot
    nonisolated var permission: PermissionStatus { .notRequired }
    func run() async { CaptureCoordinator.shared.capture(CaptureRequest(mode: .region)) }
}

@MainActor
struct CaptureWindowProvider: ActionProvider {
    nonisolated let itemKey: BuiltinItem = .captureWindow
    nonisolated var permission: PermissionStatus { .notRequired }
    func run() async { CaptureCoordinator.shared.capture(CaptureRequest(mode: .window)) }
}

@MainActor
struct CaptureFullscreenProvider: ActionProvider {
    nonisolated let itemKey: BuiltinItem = .captureFullscreen
    nonisolated var permission: PermissionStatus { .notRequired }
    func run() async { CaptureCoordinator.shared.capture(CaptureRequest(mode: .fullscreen)) }
}

@MainActor
struct CaptureTimerProvider: ActionProvider {
    nonisolated let itemKey: BuiltinItem = .captureTimer
    nonisolated var permission: PermissionStatus { .notRequired }
    func run() async {
        CaptureCoordinator.shared.capture(CaptureRequest(mode: .region, delay: CaptureSettings.shared.delaySeconds))
    }
}

@MainActor
struct CaptureModeBarProvider: ActionProvider {
    nonisolated let itemKey: BuiltinItem = .captureModeBar
    nonisolated var permission: PermissionStatus { .notRequired }
    func run() async { CaptureCoordinator.shared.presentModeBar() }
}
```

Note: confirm `PermissionStatus.notRequired` is the correct spelling (existing
providers use `.notRequired`). If `ActionProvider` requires `run()` to be
`async throws`, change the signatures to `func run() async throws`. If the
providers cannot be `@MainActor struct` under the protocol's `Sendable`
requirement, fall back to `actor` (like existing providers) and hop to the main
actor inside `run()` with `await MainActor.run { CaptureCoordinator.shared.capture(...) }`.

- [ ] **Step 2: Delete the old provider**

Run: `git rm Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift`

- [ ] **Step 3: Wire AppDelegate**

In `Sources/AnyDoor/AppDelegate.swift`, in the `providers` array, replace the line
`ScreenshotProvider(),` with:

```swift
    CaptureRegionProvider(),
    CaptureWindowProvider(),
    CaptureFullscreenProvider(),
    CaptureTimerProvider(),
    CaptureModeBarProvider(),
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds. Resolve provider isolation/signature issues per the note in Step 1.

- [ ] **Step 5: Manual end-to-end verification**

Run: `swift run AnyDoor` (grant Accessibility + Screen Recording when prompted).
Verify:
- The panel shows the new "窗口截图 / 全屏截图 / 定时截图 / 截图菜单" rows.
- Region capture: drag a rect → frozen backdrop dims, selection shows through, dimension label tracks → on release a quick-access overlay appears next to the region with the thumbnail and action row → auto-copies (paste into Notes) and auto-saves to `~/Pictures/AnyDoor`.
- Window capture: hover highlights windows → click captures one with transparency/shadow.
- Fullscreen: captures the screen under the mouse.
- Timer: waits the configured seconds before grabbing.
- Overlay actions: Copy, Save (reveals in Finder), Edit (opens placeholder window + Dock icon appears), Pin (floating window with opacity/click-through), Extract Text (OCR → clipboard), Re-capture, Delete.
- Mode bar (`截图菜单`): bar appears; digit keys 1–4 and clicks pick modes; Esc dismisses.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/CaptureProviders.swift Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(capture): wire capture providers and remove legacy screenshot provider"
```

---

## Task 18: Command palette entries + timer delay submenu

**Files:**
- Modify: `Sources/AnyDoor/Services/CommandPaletteOptions.swift`

The five capture builtins already surface in the command palette automatically
(they are `.action` builtins). This task adds the timer's second-level delay menu.

- [ ] **Step 1: Make `.captureTimer` an option parent**

In `isOptionParent(_:)`, add `.captureTimer`:

```swift
static func isOptionParent(_ item: BuiltinItem) -> Bool {
    switch item {
    case .keepAwake, .scheduledShutdown, .brightness, .hostsManager, .portManager, .pickColor, .captureTimer: return true
    default: return false
    }
}
```

- [ ] **Step 2: Add the delay options builder**

Add this method near `keepAwakeOptions` (mirrors its structure):

```swift
static func captureTimerOptions() -> [CommandPaletteOption] {
    [3, 5, 10].map { seconds in
        CommandPaletteOption(
            id: "captureTimer.delay\(seconds)",
            title: L(.captureDelaySeconds, seconds),
            symbol: "timer",
            perform: {
                CaptureSettings.shared.setDelaySeconds(seconds)
                CaptureCoordinator.shared.capture(CaptureRequest(mode: .region, delay: seconds))
            }
        )
    }
}
```

- [ ] **Step 3: Route the parent to the builder**

Find where the other option parents build their option arrays (the switch/dispatch
that maps `.keepAwake` → `keepAwakeOptions(...)`, etc.) and add the `.captureTimer`
arm calling `captureTimerOptions()`. Match the exact call shape used by the
neighboring cases in that function.

- [ ] **Step 4: Build + test**

Run: `swift build`
Then: `swift test --filter CommandPaletteOptionsTests`
Expected: builds; existing palette-options tests pass.

- [ ] **Step 5: Manual verification**

`swift run AnyDoor` → open the command palette → type "定时" → drilling into 定时截图 shows 3/5/10s options; picking one starts a delayed region capture.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/CommandPaletteOptions.swift
git commit -m "feat(capture): add timed-capture delay submenu to command palette"
```

---

## Task 19: Config-sync reconcile hook

**Files:**
- Modify: wherever `reconcileAfterImport` re-reads services (search for `HyperKeyService.shared` / `reloadFromDefaults` in the backup/import path, per CLAUDE.md "reconcileAfterImport").

- [ ] **Step 1: Add CaptureSettings reload to reconcile**

Find the import-reconcile function (it already calls `reloadFromDefaults` on
CommandPaletteService / LocalizationManager / HyperKeyService / ScheduledShutdownService).
Add:

```swift
CaptureSettings.shared.reloadFromDefaults()
```

alongside the other `reloadFromDefaults()` calls so imported capture settings apply
without relaunch.

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat(capture): reload capture settings after config import"
```

---

## Task 20: Full test + build sweep

- [ ] **Step 1: Run the whole suite**

Run: `swift test`
Expected: all tests pass, including the new `CaptureFilenameTests`,
`SelectionGeometryTests`, `WindowEnumeratorTests`, `OverlayPlacementTests`,
`CaptureModeBarPolicyTests`, `CaptureSettingsTests`, and the unchanged existing tests.

- [ ] **Step 2: Release build**

Run: `swift build -c release`
Expected: builds clean.

- [ ] **Step 3: Update CHANGELOG**

Add under `## [Unreleased]` in `CHANGELOG.md` an `### Added` entry describing the
capture suite (region/window/fullscreen/timed capture, freeze-screen selection
with magnifier, quick-access overlay with copy/save/edit/pin/OCR/re-capture/delete,
All-In-One mode bar, pin-to-screen). Keep it concise and English.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(capture): note Phase 0 capture suite in changelog"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Four capture kinds → Tasks 16/17 (region/window/fullscreen + timer via delay).
- Discrete hotkeys + All-In-One bar → Task 9 (builtins/hotkeys), Task 15 (bar), Task 17 (wiring).
- Custom freeze-screen selection UI with crosshair/dimensions/magnifier-source → Task 11.
- ScreenCaptureKit grabs → Task 8.
- Quick-access overlay following the region, all actions implemented → Task 14 + Task 16.
- Pin window → Task 12.
- Placeholder editor → Task 13.
- Auto-save + auto-copy + history → Task 16 + Task 10.
- OCR reuse on overlay → Task 16. OCR/QR/color left as-is → unchanged (only `.screenshot` swapped).
- Command palette + timer submenu → Task 18.
- Permission gating → Task 16. Config sync entries + reconcile → Task 7 + Task 19.
- Window policy (.regular for editor) → Task 13. Non-activating panels → Tasks 11/12/14/15.
- Pure-logic unit tests → Tasks 2–7.

**Open risks flagged for the executor (not placeholders — real implementations provided, but verify against the live API):**
- `SelectionOverlayView` coordinate conversions (multi-display, backing scale, CGWindow flip) — verified in Task 17 Step 5; adjust if region crop or window highlight is misaligned.
- `ActionProvider` isolation/signature (`@MainActor struct` vs `actor`, `async` vs `async throws`) — note in Task 17 Step 1.
- `TextRecognizer.recognize` / `ToastPresenter` / `ClipboardWatcher` exact signatures — noted in Task 16.
- The option-parent dispatch site in `CommandPaletteOptions` — Task 18 Step 3 says to match the neighboring cases.
```
