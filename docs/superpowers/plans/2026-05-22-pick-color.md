# Pick Color Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a built-in screen color picker that shows the macOS system color loupe, copies the picked color to the clipboard as an uppercase HEX string, and confirms with a toast.

**Architecture:** A new `BuiltinItem.pickColor` action item, backed by an `actor PickColorProvider` modeled on `OCRProvider`. The provider calls a `@MainActor ColorSampler` helper that wraps `NSColorSampler` (the system loupe) in `async`. Color-to-HEX conversion lives in a testable `NSColor` extension. The existing toast gains a `.color` style that shows a color swatch instead of an SF Symbol.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6` language mode), AppKit (`NSColorSampler`, `NSColor`, `NSPasteboard`), SwiftUI (`Color`, toast view), XCTest.

---

## File Structure

**New files:**

- `Sources/AnyDoor/Utilities/NSColor+Hex.swift` — `NSColor.sRGBHexString` computed property. Pure, testable color-to-HEX conversion.
- `Sources/AnyDoor/Services/ColorSampler.swift` — `@MainActor enum ColorSampler` adapting `NSColorSampler`'s completion-handler API into `async`, returning a `Sendable` outcome.
- `Sources/AnyDoor/Services/Providers/PickColorProvider.swift` — `actor PickColorProvider: ActionProvider`. Orchestrates loupe → clipboard → toast.
- `Tests/AnyDoorTests/ColorHexTests.swift` — unit tests for `sRGBHexString`.

**Modified files:**

- `Sources/AnyDoor/Models/BuiltinItem.swift` — add the `.pickColor` catalog case.
- `Sources/AnyDoor/Views/ToastView.swift` — add `ToastStyle.color` and a swatch branch in `ToastView`.
- `Sources/AnyDoor/AppDelegate.swift` — register `PickColorProvider()`.
- `Tests/AnyDoorTests/MigrationTests.swift` — extend `BuiltinItemTests` with `.pickColor` assertions.

**Task dependency order:** Task 1 (hex) → Task 2 (catalog) → Task 3 (sampler, needs Task 1) → Task 4 (toast) → Task 5 (provider, needs Tasks 1-4) → Task 6 (manual verification).

---

## Task 1: NSColor → HEX conversion

**Files:**
- Create: `Sources/AnyDoor/Utilities/NSColor+Hex.swift`
- Test: `Tests/AnyDoorTests/ColorHexTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/ColorHexTests.swift`:

```swift
import XCTest
import AppKit
@testable import AnyDoor

final class ColorHexTests: XCTestCase {

    func testBlackProducesAllZeroes() {
        XCTAssertEqual(NSColor.black.sRGBHexString, "#000000")
    }

    func testWhiteProducesAllFs() {
        XCTAssertEqual(NSColor.white.sRGBHexString, "#FFFFFF")
    }

    func testMidToneColorRoundsEachChannel() {
        // 0.5*255=127.5→128 (0x80), 0.25*255=63.75→64 (0x40), 0.75*255=191.25→191 (0xBF)
        let color = NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        XCTAssertEqual(color.sRGBHexString, "#8040BF")
    }

    func testComponentsOutsideUnitRangeAreClamped() {
        // Wide-gamut conversions can yield components slightly outside 0...1.
        // red 1.4 clamps to 1→FF, green -0.2 clamps to 0→00, blue 1.0→FF.
        let color = NSColor(srgbRed: 1.4, green: -0.2, blue: 1.0, alpha: 1)
        XCTAssertEqual(color.sRGBHexString, "#FF00FF")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ColorHexTests`
Expected: FAIL — compile error `value of type 'NSColor' has no member 'sRGBHexString'`.

- [ ] **Step 3: Write the implementation**

Create `Sources/AnyDoor/Utilities/NSColor+Hex.swift`:

```swift
import AppKit

extension NSColor {
    /// The color as an uppercase `"#RRGGBB"` string in the sRGB color space.
    ///
    /// Returns `nil` when the color cannot be converted to sRGB (e.g. pattern
    /// colors). Each component is clamped to `0...1` before scaling — sampling
    /// on wide-gamut displays can yield components slightly outside that range.
    var sRGBHexString: String? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int {
            Int((min(max(value, 0), 1) * 255).rounded())
        }
        return String(
            format: "#%02X%02X%02X",
            channel(srgb.redComponent),
            channel(srgb.greenComponent),
            channel(srgb.blueComponent)
        )
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ColorHexTests`
Expected: PASS — 4 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Utilities/NSColor+Hex.swift Tests/AnyDoorTests/ColorHexTests.swift
git commit -m "feat(color): add NSColor sRGB hex conversion"
```

---

## Task 2: BuiltinItem.pickColor catalog entry

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Test: `Tests/AnyDoorTests/MigrationTests.swift` (extend `BuiltinItemTests`)

- [ ] **Step 1: Write the failing test**

In `Tests/AnyDoorTests/MigrationTests.swift`, inside `final class BuiltinItemTests`, add these two methods after `testOCRMetadata()` (before the closing `}` of the class):

```swift
    func testPickColorIsAnActionItem() {
        XCTAssertEqual(BuiltinItem.pickColor.kind, .action)
    }

    func testPickColorMetadata() {
        XCTAssertEqual(BuiltinItem.pickColor.title, "屏幕取色")
        XCTAssertEqual(BuiltinItem.pickColor.symbol, "eyedropper")
        XCTAssertEqual(BuiltinItem.pickColor.defaultOrder, 975)
        XCTAssertFalse(BuiltinItem.pickColor.requiresAutomation)
        XCTAssertNil(BuiltinItem.pickColor.feedbackSound)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BuiltinItemTests`
Expected: FAIL — compile error `type 'BuiltinItem' has no member 'pickColor'`.

- [ ] **Step 3: Add the enum case**

In `Sources/AnyDoor/Models/BuiltinItem.swift`, add `case pickColor` immediately after `case ocr`:

```swift
    case ocr
    case pickColor
    case displaySleep
```

- [ ] **Step 4: Add `.pickColor` to the `kind` action group**

In the `var kind: Kind` switch, replace the `.action` case:

Old:
```swift
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
```

New:
```swift
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
```

- [ ] **Step 5: Add the `title` case**

In `var title: String`, add after the `.ocr` line:

```swift
        case .ocr: return "屏幕取词"
        case .pickColor: return "屏幕取色"
```

- [ ] **Step 6: Add the `symbol` case**

In `var symbol: String`, add after the `.ocr` line:

```swift
        case .ocr: return "text.viewfinder"
        case .pickColor: return "eyedropper"
```

- [ ] **Step 7: Add the `defaultOrder` case**

In `var defaultOrder: Double`, add after the `.ocr` line:

```swift
        case .ocr: return 950
        case .pickColor: return 975
```

Note: `requiresAutomation` and `feedbackSound` both have `default:` clauses, so they need no change — `.pickColor` falls through to `false` / `nil`.

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter BuiltinItemTests`
Expected: PASS — `BuiltinItemTests` all pass, including `testAllCasesHaveDistinctOrder` (975 is unique between ocr 950 and displaySleep 1000).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(panel): add pick-color builtin catalog entry"
```

---

## Task 3: ColorSampler async loupe wrapper

**Files:**
- Create: `Sources/AnyDoor/Services/ColorSampler.swift`

No unit test: `NSColorSampler` presents real interactive system UI and cannot be exercised headlessly. Verified by compilation here and manually in Task 6.

- [ ] **Step 1: Write the implementation**

Create `Sources/AnyDoor/Services/ColorSampler.swift`:

```swift
import AppKit
import SwiftUI

/// Adapts `NSColorSampler`'s completion-handler API into `async`.
///
/// `NSColorSampler` presents the macOS system color-sampling loupe and must be
/// used on the main thread. The picked `NSColor` is converted to `Sendable`
/// values inside the completion handler so it never crosses an actor boundary.
@MainActor
enum ColorSampler {
    /// The result of one color-sampling session.
    enum Outcome: Sendable {
        /// The user picked a color: `hex` is `"#RRGGBB"`, `swatch` previews it.
        case picked(hex: String, swatch: Color)
        /// A color was picked but could not be represented in sRGB.
        case conversionFailed
        /// The user dismissed the loupe without picking (e.g. pressed Escape).
        case cancelled
    }

    /// Presents the system color loupe and waits for the user to pick a pixel
    /// or cancel.
    static func sample() async -> Outcome {
        await withCheckedContinuation { continuation in
            NSColorSampler().show { color in
                guard let color else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                guard let hex = color.sRGBHexString else {
                    continuation.resume(returning: .conversionFailed)
                    return
                }
                continuation.resume(
                    returning: .picked(hex: hex, swatch: Color(nsColor: color))
                )
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no warnings about `ColorSampler.swift`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/ColorSampler.swift
git commit -m "feat(color): add ColorSampler async loupe wrapper"
```

---

## Task 4: Color swatch toast style

**Files:**
- Modify: `Sources/AnyDoor/Views/ToastView.swift`

No unit test: `ToastView` is a SwiftUI view; rendering is verified manually in Task 6. The change is build-verified here.

- [ ] **Step 1: Replace the contents of `ToastView.swift`**

`ToastStyle` gains a `.color` case and `ToastView` switches on the style for its leading element. The per-style `iconName` / `iconColor` accessors are removed (they were only ever used inside `ToastView`; confirm with the grep in Step 2).

Replace the entire contents of `Sources/AnyDoor/Views/ToastView.swift` with:

```swift
import SwiftUI

/// The status a toast reports. `Sendable` so it can cross provider actor →
/// `ToastPresenter` (`@MainActor`) boundaries. `Color` is `Sendable`, so the
/// `.color` swatch crosses the boundary unchanged.
enum ToastStyle: Sendable {
    case success(String)
    case failure(String)
    case color(message: String, swatch: Color)

    var message: String {
        switch self {
        case .success(let text), .failure(let text):
            return text
        case .color(let message, _):
            return message
        }
    }
}

/// A compact status pill: a leading icon or color swatch next to one line of text.
struct ToastView: View {
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            leading
            Text(verbatim: style.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }

    /// SF Symbol for success/failure; a bordered color swatch for `.color`.
    @ViewBuilder
    private var leading: some View {
        switch style {
        case .success:
            symbol("checkmark.circle.fill", color: .green)
        case .failure:
            symbol("xmark.circle.fill", color: .red)
        case .color(_, let swatch):
            RoundedRectangle(cornerRadius: 4)
                .fill(swatch)
                .frame(width: 16, height: 16)
                // Thin border keeps near-white swatches visible on the material.
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                )
        }
    }

    private func symbol(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color)
    }
}
```

- [ ] **Step 2: Verify no other file referenced the removed accessors**

Run: `grep -rn "iconName\|iconColor" Sources/`
Expected: no matches. (If any appear, they must be updated — but `ToastStyle` was the only definer and `ToastView` the only consumer.)

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` — `OCRProvider`'s existing `.success` / `.failure` calls still typecheck.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/ToastView.swift
git commit -m "feat(toast): add color swatch toast style"
```

---

## Task 5: PickColorProvider and registration

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/PickColorProvider.swift`
- Modify: `Sources/AnyDoor/AppDelegate.swift:44-63`

No unit test: the provider drives interactive system UI (`NSColorSampler`) and writes the system pasteboard. Behavior is verified manually in Task 6; the full test suite is run here to confirm no regression.

- [ ] **Step 1: Write the provider**

Create `Sources/AnyDoor/Services/Providers/PickColorProvider.swift`:

```swift
import AppKit
import Foundation

/// Presents the macOS system color-sampling loupe, copies the picked color to
/// the clipboard as an uppercase HEX string, and shows a bottom-center toast
/// reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor PickColorProvider: ActionProvider {
    let itemKey: BuiltinItem = .pickColor

    var permission: PermissionStatus { .notRequired }

    func run() async {
        switch await ColorSampler.sample() {
        case .cancelled:
            return // user cancelled — silent, no toast
        case .conversionFailed:
            await ToastPresenter.shared.show(.failure("取色失败"))
        case .picked(let hex, let swatch):
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(hex, forType: .string)
            }
            await ToastPresenter.shared.show(
                .color(message: "已复制 \(hex)", swatch: swatch)
            )
        }
    }
}
```

- [ ] **Step 2: Register the provider in `AppDelegate`**

In `Sources/AnyDoor/AppDelegate.swift`, add `PickColorProvider()` to the `providers` array. Replace:

Old:
```swift
            KeyboardLockProvider(),
            OCRProvider(),
        ]
```

New:
```swift
            KeyboardLockProvider(),
            OCRProvider(),
            PickColorProvider(),
        ]
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 4: Run the full test suite to confirm no regression**

Run: `swift test`
Expected: all tests pass. `PanelStoreTests.testTopLevelEntriesCount` and `MigrationTests` seeding tests derive counts from `BuiltinItem.allCases`, so the new case does not break them.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/PickColorProvider.swift Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(panel): add screen color picker action"
```

---

## Task 6: Manual verification

**Files:** none — runtime verification only.

`NSColorSampler`, the system pasteboard, and the toast window cannot be exercised by the headless test suite. Verify the feature by running the app.

- [ ] **Step 1: Launch the app**

Run: `swift run AnyDoor`
Expected: the menu bar icon appears. Grant Accessibility permission if prompted (System Settings → Privacy & Security → Accessibility).

- [ ] **Step 2: Verify the panel row**

Open the menu bar panel. Expected: a `屏幕取色` row with an eyedropper icon appears, positioned just below `屏幕取词` (OCR).

- [ ] **Step 3: Verify a successful pick**

Click `屏幕取色`. Expected: the system color loupe appears. Hover over a known-color region (e.g. a pure-red swatch) and click. Expected: a bottom-center toast shows a color swatch plus `已复制 #RRGGBB`. Paste into a text field and confirm the clipboard holds that exact uppercase HEX string.

- [ ] **Step 4: Verify cancellation**

Click `屏幕取色`, then press Escape while the loupe is showing. Expected: no toast, and the clipboard is unchanged.

- [ ] **Step 5: Verify the hotkey path**

In the panel settings (`面板` tab), record a hotkey for `屏幕取色`. Close settings, press the hotkey. Expected: the loupe appears exactly as it does from the panel row.

- [ ] **Step 6: Report**

Report the results of Steps 2-5. If all pass, the feature is complete.

---

## Notes on spec deviations

- The spec (`docs/superpowers/specs/2026-05-22-pick-color-design.md`) places the `NSColor` → HEX conversion inside `PickColorProvider`. This plan moves it into `ColorSampler` (on `@MainActor`) because `NSColor` is not `Sendable` and cannot cross from `ColorSampler` (`@MainActor`) to `PickColorProvider` (an `actor`). `ColorSampler.sample()` returns a `Sendable` `Outcome` enum that preserves the spec's three outcomes (picked / conversion-failed / cancelled), so the provider still owns every clipboard and toast decision. Behavior matches the spec exactly.
- The swatch border uses `Color(nsColor: .separatorColor)` — the system separator color — rather than an unspecified stroke; this is the concrete realization of the spec's "thin `.separator` stroke".
