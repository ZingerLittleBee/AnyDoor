# QR Code Recognition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a QR-code recognition action to AnyDoor that captures a screen region, decodes any QR codes inside it with the macOS Vision framework, copies the payload(s) to the clipboard, and shows a transient bottom-center toast reporting status (never showing the payload itself).

**Architecture:** Mirror the existing OCR pipeline. `QRCodeProvider` (an `actor`) orchestrates two isolated units — `RegionCapture` (reused unchanged) and a new `BarcodeRecognizer` (Vision wrapper). The clipboard write and toast hop through the existing `ToastPresenter` singleton. A single new `BuiltinItem.qrcode` case wires the row into the panel via `BuiltinPreferenceSeeder` and the `ActionProvider` dispatch path. No changes to `RegionCapture`, `ShellRunner`, `PanelStore`, or `ToastPresenter`.

**Tech Stack:** Swift 6.2 (strict concurrency, language mode v6), macOS 14+ deployment target, SwiftUI + AppKit, Vision framework (`VNDetectBarcodesRequest`), Core Image (`CIFilter.qrCodeGenerator` for test fixtures), SPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-24-qrcode-recognition-design.md`

---

## File Structure

**New files:**

- `Sources/AnyDoor/Services/BarcodeRecognizer.swift` — Vision QR-decode wrapper. Pure, UI-free, shell-free. Parallels `TextRecognizer`.
- `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift` — `ActionProvider` orchestrating capture → decode → clipboard → toast. Parallels `OCRProvider`.
- `Tests/AnyDoorTests/BarcodeRecognizerTests.swift` — recognition tests with programmatically generated QR images (Core Image).

**Modified files:**

- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `case qrcode` with its `kind`, `title`, `symbol`, `defaultOrder` entries.
- `Sources/AnyDoor/AppDelegate.swift:67` — register `QRCodeProvider()` in the `providers` array, immediately after `OCRProvider()`.
- `Tests/AnyDoorTests/MigrationTests.swift` — extend `BuiltinItemTests` with `.qrcode` assertions.

**Untouched (reused as-is):**

- `Sources/AnyDoor/Services/RegionCapture.swift` — already generic; the `OCRError.imageDecodeFailed` case it throws is acceptable for `QRCodeProvider` to catch and surface as "识别失败". (Renaming `OCRError` is out of scope per the spec.)
- `Sources/AnyDoor/Services/PanelStore.swift` — `run(_:)`'s per-item in-flight guard already covers every `ActionProvider`, so `QRCodeProvider` is automatically protected against re-trigger overlap.
- `Sources/AnyDoor/Views/ToastPresenter.swift`, `ToastView.swift` — `ToastStyle.success(String)` / `.failure(String)` are sufficient.
- `Sources/AnyDoor/Services/ShellRunner.swift` — optional timeout already in place from the OCR work.
- `Sources/AnyDoor/Services/BuiltinPreferenceSeeder.swift` — iterates `BuiltinItem.allCases`; the new case is picked up automatically.

**Test approach note:** Following the OCR plan's precedent, QR test fixtures are generated programmatically with Core Image's `CIQRCodeGenerator` filter inside the test (no binary blobs committed). This exercises the real Vision detector and is fully reproducible.

---

## Task 1: BarcodeRecognizer + tests

**Files:**
- Create: `Sources/AnyDoor/Services/BarcodeRecognizer.swift`
- Create: `Tests/AnyDoorTests/BarcodeRecognizerTests.swift`

Pure Vision wrapper. Mirrors `TextRecognizer.recognize` in structure: dispatch onto a background queue, run a `VNImageRequestHandler`, sort observations top-to-bottom, return strings.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/BarcodeRecognizerTests.swift`:

```swift
import XCTest
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
@testable import AnyDoor

/// `@MainActor` because the helper composites with AppKit (`NSImage.lockFocus`),
/// which must run on the main thread.
@MainActor
final class BarcodeRecognizerTests: XCTestCase {

    /// Generates one QR code per payload and composites them vertically on a
    /// white canvas, first payload at the top. Returns the rasterized CGImage.
    private func renderImage(payloads: [String]) throws -> CGImage {
        let cellSize: CGFloat = 200
        let padding: CGFloat = 40
        let width: CGFloat = cellSize + padding * 2
        let height = padding * 2 + cellSize * CGFloat(max(payloads.count, 1))
            + padding * CGFloat(max(payloads.count - 1, 0))
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let context = CIContext()
        for (index, payload) in payloads.enumerated() {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(payload.utf8)
            filter.correctionLevel = "M"
            guard let output = filter.outputImage else {
                throw XCTSkip("failed to generate QR image for \(payload)")
            }
            // Scale up from the filter's native 1-module-per-pixel output.
            let scale = cellSize / output.extent.width
            let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let cg = context.createCGImage(scaled, from: scaled.extent) else {
                throw XCTSkip("failed to rasterize QR image for \(payload)")
            }
            // AppKit origin is bottom-left; draw the first payload near the top.
            let y = height - padding - cellSize * CGFloat(index + 1)
                - padding * CGFloat(index)
            let drawRect = NSRect(x: padding, y: y, width: cellSize, height: cellSize)
            NSGraphicsContext.current?.cgContext.draw(cg, in: drawRect)
        }
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("failed to rasterize the test image")
        }
        return cgImage
    }

    func testDecodesSingleQRCode() async throws {
        let payload = "https://example.com/anydoor"
        let image = try renderImage(payloads: [payload])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result, [payload])
    }

    func testReturnsCodesTopToBottom() async throws {
        let top = "FIRST"
        let bottom = "SECOND"
        let image = try renderImage(payloads: [top, bottom])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result.count, 2, "expected two payloads; got: \(result)")
        XCTAssertEqual(result.first, top)
        XCTAssertEqual(result.last, bottom)
    }

    func testBlankImageReturnsEmpty() async throws {
        let image = try renderImage(payloads: [])
        let result = try await BarcodeRecognizer.scan(image)
        XCTAssertEqual(result, [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BarcodeRecognizerTests`
Expected: compile failure (`BarcodeRecognizer` is undefined).

- [ ] **Step 3: Implement `BarcodeRecognizer`**

Create `Sources/AnyDoor/Services/BarcodeRecognizer.swift`:

```swift
import CoreGraphics
import Foundation
import Vision

/// Decodes QR codes in a still image using the macOS Vision framework.
///
/// Restricted to QR symbology only; other barcode types (EAN, Code 128, Aztec,
/// ...) are ignored even if present in the image.
enum BarcodeRecognizer {
    /// Decodes every QR code in `image`. Returns one string per code, ordered
    /// top-to-bottom by bounding-box position. An empty array means no QR code
    /// was found (not an error).
    static func scan(_ image: CGImage) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNDetectBarcodesRequest()
                    request.symbologies = [.qr]

                    let handler = VNImageRequestHandler(cgImage: image, options: [:])
                    try handler.perform([request])

                    let observations = request.results ?? []
                    // Vision's normalized coordinate space has Y increasing upward,
                    // so the top-most code has the largest boundingBox.maxY.
                    let payloads = observations
                        .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
                        .compactMap { observation -> String? in
                            guard let value = observation.payloadStringValue,
                                  !value.isEmpty else { return nil }
                            return value
                        }
                    continuation.resume(returning: payloads)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BarcodeRecognizerTests`
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/BarcodeRecognizer.swift Tests/AnyDoorTests/BarcodeRecognizerTests.swift
git commit -m "feat(qr): add BarcodeRecognizer Vision wrapper"
```

---

## Task 2: BuiltinItem.qrcode

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Modify: `Tests/AnyDoorTests/MigrationTests.swift`

Add the new built-in catalog case. Five `switch` statements in `BuiltinItem.swift` need new branches (cases list, `kind`, `title`, `symbol`, `defaultOrder`). `requiresAutomation` and `feedbackSound` fall through to their default branches and need no change.

- [ ] **Step 1: Write the failing test**

Append to `BuiltinItemTests` in `Tests/AnyDoorTests/MigrationTests.swift` (next to the existing `.ocr` and `.pickColor` assertions around line 49–65):

```swift
func testQRCodeItem() {
    XCTAssertEqual(BuiltinItem.qrcode.kind, .action)
    XCTAssertEqual(BuiltinItem.qrcode.title, "识别二维码")
    XCTAssertEqual(BuiltinItem.qrcode.symbol, "qrcode.viewfinder")
    XCTAssertEqual(BuiltinItem.qrcode.defaultOrder, 960)
    XCTAssertFalse(BuiltinItem.qrcode.requiresAutomation)
    XCTAssertNil(BuiltinItem.qrcode.feedbackSound)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter BuiltinItemTests`
Expected: compile failure (`BuiltinItem.qrcode` is undefined).

- [ ] **Step 3: Add the case to `BuiltinItem`**

In `Sources/AnyDoor/Models/BuiltinItem.swift`, make these four edits.

1. Add to the cases list (after `case pickColor` at line 16):

```swift
    case pickColor
    case qrcode
```

2. Add to the `kind` switch (extend the `.action` branch around line 39):

```swift
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .qrcode, .pickColor, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
```

3. Add to the `title` switch (after the `.pickColor` line around line 56):

```swift
        case .pickColor: return "屏幕取色"
        case .qrcode: return "识别二维码"
```

4. Add to the `symbol` switch (after the `.pickColor` line around line 82):

```swift
        case .pickColor: return "eyedropper"
        case .qrcode: return "qrcode.viewfinder"
```

5. Add to the `defaultOrder` switch (after the `.pickColor` line around line 109):

```swift
        case .pickColor: return 975
        case .qrcode: return 960
```

Note: 960 places the new row between OCR (950) and 屏幕取色 (975) on fresh installs only. Existing installs receive it appended at the end by `BuiltinPreferenceSeeder` (the seeder's standing contract); the user can reorder it in panel settings.

`requiresAutomation` and `feedbackSound` need no edit — their `default` branches cover the new case.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BuiltinItemTests`
Expected: all `BuiltinItemTests` assertions PASS, including the new `.qrcode` case.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(qr): add BuiltinItem.qrcode catalog entry"
```

---

## Task 3: QRCodeProvider

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift`

`actor` that orchestrates the capture → decode → clipboard → toast pipeline. Mirrors `OCRProvider` exactly — same structure, swapped recognizer, swapped toast strings.

No automated test: the provider depends on the interactive `screencapture` selection UI and `ToastPresenter`'s `NSPanel`, both of which require a real GUI session. Manual verification happens in Task 5.

- [ ] **Step 1: Implement `QRCodeProvider`**

Create `Sources/AnyDoor/Services/Providers/QRCodeProvider.swift`:

```swift
import AppKit
import Foundation

/// Captures a screen region, decodes any QR codes inside it with Vision, copies
/// the payload(s) to the clipboard, and shows a bottom-center toast reporting
/// the outcome.
///
/// The toast text is status only — it never includes the decoded payload, by
/// design.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor QRCodeProvider: ActionProvider {
    let itemKey: BuiltinItem = .qrcode

    var permission: PermissionStatus { .notRequired }

    func run() async {
        do {
            guard let image = try await RegionCapture.captureRegion() else {
                return // user cancelled — silent, no toast
            }
            let payloads = try await BarcodeRecognizer.scan(image)
            guard !payloads.isEmpty else {
                await ToastPresenter.shared.show(.failure("未识别到二维码"))
                return
            }
            let text = payloads.joined(separator: "\n")
            await MainActor.run {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
            await ToastPresenter.shared.show(.success("已复制到剪贴板"))
        } catch {
            await ToastPresenter.shared.show(.failure("识别失败"))
        }
    }
}
```

- [ ] **Step 2: Verify the build compiles**

Run: `swift build`
Expected: build succeeds with no warnings about `QRCodeProvider`.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/QRCodeProvider.swift
git commit -m "feat(qr): add QRCodeProvider orchestrating capture and decode"
```

---

## Task 4: Register QRCodeProvider in AppDelegate

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift:67`

Add one line to the providers array so `PanelStore` knows about the new provider and the panel row dispatches to it.

- [ ] **Step 1: Insert the registration line**

In `Sources/AnyDoor/AppDelegate.swift`, locate the `providers` array (the line that reads `OCRProvider(),` around line 67) and add `QRCodeProvider()` immediately after it:

```swift
            OCRProvider(),
            QRCodeProvider(),
            PickColorProvider(),
```

- [ ] **Step 2: Verify the build compiles**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests PASS, including the new `BarcodeRecognizerTests` and the updated `BuiltinItemTests`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(qr): register QRCodeProvider in AppDelegate"
```

---

## Task 5: Manual verification

**Files:** none modified.

The interactive pieces (`screencapture` selection, `ToastPresenter` window, real clipboard write) can only be verified by running the app. Walk through each case and confirm the expected outcome before declaring the feature done.

- [ ] **Step 1: Launch the app**

Run: `swift run AnyDoor`
Expected: the menu bar icon appears. If the app prompts for Accessibility permission, grant it and re-run.

- [ ] **Step 2: Verify the panel row exists**

Open the menu bar panel. Confirm the "识别二维码" row is present with the QR icon (`qrcode.viewfinder`). On a fresh install it appears between "屏幕取词" and "屏幕取色"; on an existing install it appears at the bottom of the panel (drag it where you want it in panel settings).

- [ ] **Step 3: Successful single-code decode**

Open a QR code somewhere on screen (e.g. `https://qrcode.show/https://example.com` in a browser, or any QR you already have). Trigger "识别二维码" from the panel and drag a selection rectangle around the code.

Expected:
- The toast "已复制到剪贴板" appears at the bottom-center for ~1 second.
- The clipboard contains exactly the decoded payload (paste into Notes / a terminal to confirm).
- The toast text contains **no** payload content.

- [ ] **Step 4: Multi-code decode (top-to-bottom join)**

Display two distinct QR codes vertically on screen (the easiest way: open `https://qrcode.show/FIRST` and `https://qrcode.show/SECOND` side-by-side or stacked). Trigger "识别二维码" and select a region covering both codes.

Expected:
- The toast "已复制到剪贴板" appears.
- The clipboard contains both payloads, joined with `\n`, the top code first.

- [ ] **Step 5: Empty selection**

Trigger "识别二维码" and select a region with no QR code (e.g. blank desktop).

Expected:
- The toast "未识别到二维码" appears.
- The clipboard is untouched (paste should return whatever was there before).

- [ ] **Step 6: Cancellation (Esc)**

Trigger "识别二维码" and press `Esc` during the selection.

Expected:
- No toast appears.
- The clipboard is untouched.

- [ ] **Step 7: Hotkey binding**

Open Settings → 面板, record a hotkey on the "识别二维码" row (e.g. `⌃⌥Q`), close Settings. Press the hotkey from any app.

Expected:
- The selection UI appears (same as triggering from the panel).
- After selecting a QR code, the success toast and clipboard write occur exactly as in Step 3.
- After app restart (`swift run AnyDoor` again), the hotkey still works (persisted via `BuiltinPreference`).

- [ ] **Step 8: Rapid double-trigger**

Trigger "识别二维码" twice in quick succession (panel click + hotkey press, or two hotkey presses within ~100 ms) while the selection UI is still up.

Expected:
- Only one selection UI is active. The second trigger is dropped by `PanelStore.run`'s in-flight guard.

- [ ] **Step 9: Re-trigger after completion**

Complete a full decode (Step 3), then immediately trigger again.

Expected:
- A second selection UI appears normally. The in-flight guard only blocks overlap *during* a run.

- [ ] **Step 10: Confirm panel-settings visibility / reorder still works**

Open Settings → 面板. Toggle "识别二维码" visibility off, then on again. Drag the row to a new position.

Expected:
- The row hides and reappears in the menu bar panel as expected.
- The new order persists across an app restart.

If every step above behaves as expected, the feature is done. If any step fails, file a follow-up task with the exact failure and revisit before declaring complete.

---

## Self-Review Notes

**Spec coverage:**
- "Trigger via the panel row or an assignable global hotkey" — Tasks 2 (panel row) + 4 (registration) + 5 step 7 (hotkey).
- "Capture an arbitrary screen region using `RegionCapture`" — reused unchanged, covered by Task 3 step 1 implementation.
- "Decode QR codes restricted to `.qr` symbology" — Task 1 step 3 (`request.symbologies = [.qr]`).
- "Write payload(s) to `NSPasteboard.general` newline-joined when multiple, top-to-bottom" — Task 3 step 1 implementation + Task 1 (top-to-bottom ordering by `boundingBox.maxY`) + Task 5 step 4 (verification).
- "Status-only toast; never include payload" — Task 3 step 1 implementation + Task 5 step 3 verification.
- All five error rows in the spec's Error Handling table — Task 3 step 1 implementation; Task 5 steps 5 / 6 / 8 verify the user-facing cases.
- "Default hotkey: None" — no `BuiltinPreference` seeding code paths set a hotkey, satisfied implicitly.
- "`defaultOrder = 960`" — Task 2 step 3.5 + Task 2 step 1 assertion.

No spec section is unaddressed.

**Placeholder scan:** No "TBD" / "TODO" / "handle edge cases" / "similar to" placeholders. All code shown verbatim.

**Type consistency:** `BarcodeRecognizer.scan(_:)` returns `[String]` and is referenced as such in `QRCodeProvider`. `BuiltinItem.qrcode` is referenced consistently. `ToastStyle.success(String)` / `.failure(String)` and `ToastPresenter.shared.show(_:)` match the existing `OCRProvider` call sites.
