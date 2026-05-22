# OCR Screen Text Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an OCR action to AnyDoor that captures a screen region, recognizes its text with the macOS Vision framework, copies the text to the clipboard, and shows a transient bottom-center toast reporting success or failure.

**Architecture:** A new `BuiltinItem.ocr` action wired through the existing `ActionProvider` / `PanelStore` infrastructure. `OCRProvider` (an `actor`) orchestrates three isolated units — `RegionCapture` (native `screencapture` wrapper), `TextRecognizer` (Vision wrapper), and `ToastPresenter` (a `@MainActor` toast-window singleton). Two existing files are hardened along the way: `ShellRunner` gains an optional/`nil` timeout for interactive subprocesses, and `PanelStore.run` gains a per-item in-flight guard.

**Tech Stack:** Swift 6.2 (strict concurrency, language mode v6), macOS 26, SwiftUI + AppKit, Vision framework (`RecognizeTextRequest`), SPM, XCTest.

**Spec:** `docs/superpowers/specs/2026-05-22-ocr-screen-text-design.md`

---

## File Structure

**New files:**

- `Sources/AnyDoor/Services/TextRecognizer.swift` — Vision text-recognition wrapper. Pure, UI-free, shell-free.
- `Sources/AnyDoor/Services/RegionCapture.swift` — interactive `screencapture` wrapper + `OCRError` enum. Owns the temp-file lifecycle.
- `Sources/AnyDoor/Services/Providers/OCRProvider.swift` — `ActionProvider` orchestrating capture → recognize → clipboard → toast.
- `Sources/AnyDoor/Views/ToastView.swift` — SwiftUI toast content + `ToastStyle` enum.
- `Sources/AnyDoor/Views/ToastPresenter.swift` — `@MainActor` singleton owning the toast `NSPanel`.
- `Tests/AnyDoorTests/ShellRunnerTests.swift` — timeout-behavior tests.
- `Tests/AnyDoorTests/TextRecognizerTests.swift` — recognition tests with programmatically rendered images.

**Modified files:**

- `Sources/AnyDoor/Services/ShellRunner.swift` — `timeout` becomes `TimeInterval?`; `nil` disables the watchdog.
- `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift` — pass `timeout: nil` (same interactive `screencapture`, same latent 5s-kill bug).
- `Sources/AnyDoor/Models/BuiltinItem.swift` — add `case ocr`.
- `Sources/AnyDoor/Services/PanelStore.swift` — add `actionsInFlight` guard to `run(_:)`.
- `Sources/AnyDoor/AppDelegate.swift` — register `OCRProvider()`.
- `Tests/AnyDoorTests/MigrationTests.swift` — extend `BuiltinItemTests` with `.ocr` assertions.
- `Tests/AnyDoorTests/PanelStoreTests.swift` — add the in-flight-guard test + gated stub provider.

**Test approach note:** The spec mentions a "PNG fixture under `Tests/.../Fixtures/`" for `TextRecognizer`. This plan instead renders test images programmatically (black system-font text on white) inside the test. This is a deliberate refinement — it avoids committing a binary blob, is fully reproducible, and still exercises the real Vision engine. No `Fixtures/` change is needed.

---

## Task 1: ShellRunner optional timeout (+ ScreenshotProvider fix)

**Files:**
- Modify: `Sources/AnyDoor/Services/ShellRunner.swift`
- Modify: `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift:11`
- Test: `Tests/AnyDoorTests/ShellRunnerTests.swift` (create)

`ShellRunner.run` currently always enforces a 5-second timeout. An interactive `screencapture` selection routinely exceeds 5 seconds, killing the user's selection mid-drag. Make the timeout optional; `nil` skips the watchdog.

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/ShellRunnerTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class ShellRunnerTests: XCTestCase {

    /// An explicit short timeout still terminates a long-running process.
    func testExplicitTimeoutKillsLongProcess() async {
        do {
            _ = try await ShellRunner.run("/bin/sleep", args: ["2"], timeout: 0.3)
            XCTFail("expected the watchdog to terminate the process")
        } catch BuiltinError.shellFailed(_, let output) {
            XCTAssertTrue(output.contains("timeout"), "got: \(output)")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A nil timeout disables the watchdog: the same 1s process that an explicit
    /// 0.3s timeout would kill now runs to completion.
    func testNilTimeoutDoesNotKillProcess() async throws {
        let start = Date()
        _ = try await ShellRunner.run("/bin/sleep", args: ["1"], timeout: nil)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(elapsed, 0.8, "process should have run for ~1s, not been killed early")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter ShellRunnerTests`
Expected: compile failure — `ShellRunner.run` does not accept `timeout: nil` (`timeout` is `TimeInterval`, not `TimeInterval?`).

- [ ] **Step 3: Make the timeout optional in ShellRunner**

In `Sources/AnyDoor/Services/ShellRunner.swift`, replace the entire `run` function body. The signature's `timeout` becomes `TimeInterval?`, and the watchdog loop only enforces a deadline when a timeout is set:

```swift
    /// Launch a binary with args. Returns combined stdout/stderr. Throws on non-zero exit
    /// or timeout. Pass `timeout: nil` for interactive subprocesses that have no meaningful
    /// time budget (e.g. `screencapture -i`).
    static func run(
        _ path: String,
        args: [String] = [],
        timeout: TimeInterval? = 5
    ) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()

            // Timeout watchdog — only armed when a timeout is supplied.
            let deadline = timeout.map { Date().addingTimeInterval($0) }
            while process.isRunning {
                if let deadline, Date() > deadline {
                    process.terminate()
                    let data = try? pipe.fileHandleForReading.readToEnd()
                    let output = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    throw BuiltinError.shellFailed(code: -1, output: "timeout: \(output)")
                }
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
            }

            let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                throw BuiltinError.shellFailed(code: process.terminationStatus, output: output)
            }
            return output
        }.value
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter ShellRunnerTests`
Expected: PASS (2 tests, ~1.3s total).

- [ ] **Step 5: Fix ScreenshotProvider to use the nil timeout**

In `Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift`, line 11, add `timeout: nil` to the existing call so a long screenshot selection is not killed:

```swift
            _ = try await ShellRunner.run("/usr/sbin/screencapture", args: ["-i", "-c"], timeout: nil)
```

- [ ] **Step 6: Build to verify the whole package still compiles**

Run: `swift build`
Expected: `Build complete!` with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/ShellRunner.swift Sources/AnyDoor/Services/Providers/ScreenshotProvider.swift Tests/AnyDoorTests/ShellRunnerTests.swift
git commit -m "fix(shell): support nil timeout for interactive subprocesses

ShellRunner always enforced a 5s watchdog, which kills an interactive
screencapture selection mid-drag. Make the timeout optional; nil disables
the watchdog. Apply it to ScreenshotProvider, which has the same bug."
```

---

## Task 2: Add the `BuiltinItem.ocr` case

**Files:**
- Modify: `Sources/AnyDoor/Models/BuiltinItem.swift`
- Test: `Tests/AnyDoorTests/MigrationTests.swift` (extend `BuiltinItemTests`)

- [ ] **Step 1: Write the failing test**

In `Tests/AnyDoorTests/MigrationTests.swift`, add these methods inside the existing `final class BuiltinItemTests: XCTestCase` block:

```swift
    func testOCRIsAnActionItem() {
        XCTAssertEqual(BuiltinItem.ocr.kind, .action)
    }

    func testOCRMetadata() {
        XCTAssertEqual(BuiltinItem.ocr.title, "屏幕取词")
        XCTAssertEqual(BuiltinItem.ocr.symbol, "text.viewfinder")
        XCTAssertEqual(BuiltinItem.ocr.defaultOrder, 950)
        XCTAssertFalse(BuiltinItem.ocr.requiresAutomation)
        XCTAssertNil(BuiltinItem.ocr.feedbackSound)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter BuiltinItemTests`
Expected: compile failure — `BuiltinItem` has no member `ocr`.

- [ ] **Step 3: Add the enum case**

In `Sources/AnyDoor/Models/BuiltinItem.swift`, add `case ocr` immediately after `case screenshot`:

```swift
    case screenshot
    case ocr
    case displaySleep
```

- [ ] **Step 4: Add `.ocr` to the `kind` switch**

In the `kind` computed property, add `.ocr` to the `.action` group:

```swift
        case .lockScreen, .emptyTrash, .screenshot, .ocr, .displaySleep, .systemSleep,
             .restartFinder, .restartDock, .restartMenuBar, .flushDNS: return .action
```

- [ ] **Step 5: Add `.ocr` to the `title` switch**

In the `title` computed property, add a case after `case .screenshot:`:

```swift
        case .screenshot: return "截图到剪贴板"
        case .ocr: return "屏幕取词"
```

- [ ] **Step 6: Add `.ocr` to the `symbol` switch**

In the `symbol` computed property, add a case after `case .screenshot:`:

```swift
        case .screenshot: return "camera.viewfinder"
        case .ocr: return "text.viewfinder"
```

- [ ] **Step 7: Add `.ocr` to the `defaultOrder` switch**

In the `defaultOrder` computed property, add a case after `case .screenshot: return 900`:

```swift
        case .screenshot: return 900
        case .ocr: return 950
```

`requiresAutomation` and `feedbackSound` both have a `default` arm, so `.ocr` needs no entry there.

- [ ] **Step 8: Run the test to verify it passes**

Run: `swift test --filter BuiltinItemTests`
Expected: PASS. `testAllCasesHaveDistinctOrder` still passes (950 is unique).

- [ ] **Step 9: Commit**

```bash
git add Sources/AnyDoor/Models/BuiltinItem.swift Tests/AnyDoorTests/MigrationTests.swift
git commit -m "feat(builtin): add ocr action item"
```

---

## Task 3: Add the action in-flight guard to PanelStore

**Files:**
- Modify: `Sources/AnyDoor/Services/PanelStore.swift`
- Test: `Tests/AnyDoorTests/PanelStoreTests.swift`

`PanelStore.run(_:)` has no overlap guard. An `actor` provider yields its executor at every `await`, so two hotkey presses can interleave two OCR runs that race the clipboard. Add a per-item guard mirroring the existing `togglesInFlight`.

- [ ] **Step 1: Write the failing test**

In `Tests/AnyDoorTests/PanelStoreTests.swift`, add a gated stub provider and a test. Add the stub at file scope (after the imports, before or after the existing class):

```swift
/// An ActionProvider whose `run()` blocks until `unblock()` is called, and which
/// signals (via an AsyncStream) the moment its body starts executing. Used to hold
/// one run in-flight while a second overlapping run is attempted.
actor GatedActionProvider: ActionProvider {
    let itemKey: BuiltinItem
    var permission: PermissionStatus { .notRequired }

    private(set) var runCount = 0
    private let startStream: AsyncStream<Void>
    private let startContinuation: AsyncStream<Void>.Continuation
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(itemKey: BuiltinItem) {
        self.itemKey = itemKey
        (startStream, startContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    func run() async throws {
        runCount += 1
        startContinuation.yield(())
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.releaseContinuation = continuation
        }
    }

    /// Suspends until `run()` has started executing at least once.
    func waitForStart() async {
        for await _ in startStream { return }
    }

    /// Lets the currently-suspended `run()` return.
    func unblock() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
```

Add this test method inside `final class PanelStoreTests: XCTestCase`:

```swift
    @MainActor
    func testRunDropsOverlappingCallForSameItem() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: KeyBinding.self, BuiltinPreference.self,
            configurations: config
        )
        let provider = GatedActionProvider(itemKey: .ocr)
        let store = PanelStore.shared
        store.bootstrap(modelContainer: container, providers: [provider])

        // First run: enters run(), passes the guard, and suspends inside provider.run().
        let firstRun = Task { await store.run(.ocr) }
        await provider.waitForStart()

        // Second run while the first is still in-flight — must be dropped.
        await store.run(.ocr)

        // Let the first run finish.
        await provider.unblock()
        await firstRun.value

        let count = await provider.runCount
        XCTAssertEqual(count, 1, "overlapping run for the same item must be dropped")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter testRunDropsOverlappingCallForSameItem`
Expected: FAIL — `runCount` is `2`, because `run(_:)` has no guard and the second call invokes `provider.run()` again.

- [ ] **Step 3: Add the `actionsInFlight` property**

In `Sources/AnyDoor/Services/PanelStore.swift`, add a property next to the existing `togglesInFlight` declaration (after the `togglesInFlight` line, around line 30):

```swift
    /// Per-item in-flight guard preventing overlapping toggles from desynchronizing state.
    private var togglesInFlight: Set<BuiltinItem> = []

    /// Per-item in-flight guard preventing overlapping action runs from racing.
    private var actionsInFlight: Set<BuiltinItem> = []
```

- [ ] **Step 4: Guard the `run(_:)` method**

In `Sources/AnyDoor/Services/PanelStore.swift`, replace the entire `run(_:)` method:

```swift
    /// Run a one-shot action.
    ///
    /// Guarded against overlapping calls: a second invocation for the same item while the
    /// first is mid-flight is dropped. Actor isolation alone does not serialize runs — an
    /// `actor` provider yields its executor at every `await`.
    func run(_ item: BuiltinItem) async {
        guard let provider = providers[item] as? any ActionProvider else { return }
        guard !actionsInFlight.contains(item) else { return }
        actionsInFlight.insert(item)
        defer { actionsInFlight.remove(item) }
        do {
            try await provider.run()
        } catch {
            logger.error("Run \(item.rawValue) failed: \(error)")
        }
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `swift test --filter testRunDropsOverlappingCallForSameItem`
Expected: PASS — `runCount` is `1`.

- [ ] **Step 6: Run the full PanelStore suite for regressions**

Run: `swift test --filter PanelStoreTests`
Expected: PASS (all PanelStore tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Services/PanelStore.swift Tests/AnyDoorTests/PanelStoreTests.swift
git commit -m "fix(panel): guard run against overlapping action invocations"
```

---

## Task 4: TextRecognizer (Vision wrapper)

**Files:**
- Create: `Sources/AnyDoor/Services/TextRecognizer.swift`
- Test: `Tests/AnyDoorTests/TextRecognizerTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Create `Tests/AnyDoorTests/TextRecognizerTests.swift`:

```swift
import XCTest
import AppKit
@testable import AnyDoor

/// `@MainActor` because the helper draws with AppKit (`NSImage.lockFocus`), which
/// must run on the main thread.
@MainActor
final class TextRecognizerTests: XCTestCase {

    /// Renders each string as a separate line of black system-font text on white,
    /// first element at the top. Returns the rasterized CGImage.
    private func renderImage(lines: [String]) throws -> CGImage {
        let width: CGFloat = 800
        let lineHeight: CGFloat = 100
        let height = max(lineHeight, lineHeight * CGFloat(lines.count)) + 40
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56),
            .foregroundColor: NSColor.black,
        ]
        // AppKit's origin is bottom-left; draw the first line near the top.
        for (index, line) in lines.enumerated() {
            let y = height - 40 - lineHeight * CGFloat(index) - 60
            line.draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
        }
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("failed to rasterize the test image")
        }
        return cgImage
    }

    func testRecognizesEnglishText() async throws {
        let image = try renderImage(lines: ["Hello World"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Hello"), "got: \(joined)")
        XCTAssertTrue(joined.contains("World"), "got: \(joined)")
    }

    func testRecognizesChineseText() async throws {
        let image = try renderImage(lines: ["你好世界"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined()
        XCTAssertTrue(joined.contains("你好"), "got: \(joined)")
    }

    func testReturnsLinesTopToBottom() async throws {
        let image = try renderImage(lines: ["AlphaOne", "BetaTwo"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined(separator: "\n")
        guard let alpha = joined.range(of: "AlphaOne"),
              let beta = joined.range(of: "BetaTwo") else {
            XCTFail("both lines should be recognized; got: \(joined)")
            return
        }
        XCTAssertLessThan(alpha.lowerBound, beta.lowerBound,
                          "AlphaOne (top) should precede BetaTwo (bottom); got: \(joined)")
    }

    func testBlankImageReturnsEmpty() async throws {
        let image = try renderImage(lines: [])
        let result = try await TextRecognizer.recognize(image)
        XCTAssertEqual(result, [])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter TextRecognizerTests`
Expected: compile failure — no type `TextRecognizer`.

- [ ] **Step 3: Implement TextRecognizer**

Create `Sources/AnyDoor/Services/TextRecognizer.swift`:

```swift
import CoreGraphics
import Foundation
import Vision

/// Recognizes text in a still image using the macOS Vision framework.
enum TextRecognizer {
    /// Recognizes text in `image`. Returns one string per recognized text block,
    /// ordered top-to-bottom. An empty array means no text was found (not an error).
    static func recognize(_ image: CGImage) async throws -> [String] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = [
            Locale.Language(identifier: "zh-Hans"),
            Locale.Language(identifier: "en-US"),
        ]

        let observations = try await request.perform(on: image)

        // Vision's normalized coordinate space has Y increasing upward, so the
        // top-most text block has the largest topLeft.y.
        return observations
            .sorted { $0.topLeft.y > $1.topLeft.y }
            .map(\.transcript)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter TextRecognizerTests`
Expected: PASS (4 tests). If `testRecognizesChineseText` fails, confirm `recognitionLanguages` includes `zh-Hans`.

- [ ] **Step 5: Build to verify the package compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Services/TextRecognizer.swift Tests/AnyDoorTests/TextRecognizerTests.swift
git commit -m "feat(ocr): add TextRecognizer Vision wrapper"
```

---

## Task 5: RegionCapture (screencapture wrapper)

**Files:**
- Create: `Sources/AnyDoor/Services/RegionCapture.swift`

This unit is interactive (it presents the native selection UI) and cannot be exercised by an automated test. It is build-verified here and manually verified in Task 9.

- [ ] **Step 1: Implement RegionCapture**

Create `Sources/AnyDoor/Services/RegionCapture.swift`:

```swift
import CoreGraphics
import Foundation
import ImageIO

/// Errors surfaced by the OCR capture pipeline.
enum OCRError: Error {
    /// screencapture produced a file but it could not be decoded into a CGImage.
    case imageDecodeFailed
}

/// Wraps the native macOS interactive screen-selection tool (`screencapture -i -s`).
/// Owns the temp-file lifecycle.
enum RegionCapture {
    /// Presents the macOS region-selection UI and returns the captured image.
    ///
    /// Returns `nil` when the user cancels — cancellation is detected by the
    /// *absence* of a temp file, because `screencapture`'s cancel exit code is
    /// undocumented and unreliable. Holding Control during selection routes the
    /// capture to the clipboard (native behavior), which also produces no file
    /// and is therefore treated as a cancellation.
    ///
    /// Throws `OCRError.imageDecodeFailed` when a file is produced but cannot be
    /// decoded, and rethrows any process-launch failure.
    static func captureRegion() async throws -> CGImage? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-ocr-\(UUID().uuidString).png")
        let tempPath = tempURL.path
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            // -i: interactive; -s: selection-only (disables spacebar window mode).
            // timeout nil: the user controls how long the selection takes.
            _ = try await ShellRunner.run(
                "/usr/sbin/screencapture",
                args: ["-i", "-s", tempPath],
                timeout: nil
            )
        } catch BuiltinError.shellFailed {
            // Non-zero exit. screencapture's cancel exit code is undocumented,
            // so do not treat this as a failure here — fall through to the
            // file-presence check, which is the reliable signal.
        }
        // A genuine launch failure throws a non-BuiltinError and propagates.

        guard FileManager.default.fileExists(atPath: tempPath) else {
            return nil // user cancelled, or Control-routed the capture to the clipboard
        }
        guard let image = decodeImage(at: tempURL) else {
            throw OCRError.imageDecodeFailed
        }
        return image
    }

    private static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return image
    }
}
```

- [ ] **Step 2: Build to verify the package compiles**

Run: `swift build`
Expected: `Build complete!` If the compiler reports `CGImage` is not `Sendable` at the `captureRegion` return, that is unexpected on the macOS 26 SDK (`CGImage` is `Sendable` there) — stop and report rather than adding a workaround.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/RegionCapture.swift
git commit -m "feat(ocr): add RegionCapture screencapture wrapper"
```

---

## Task 6: ToastStyle + ToastView

**Files:**
- Create: `Sources/AnyDoor/Views/ToastView.swift`

- [ ] **Step 1: Implement ToastStyle and ToastView**

Create `Sources/AnyDoor/Views/ToastView.swift`:

```swift
import SwiftUI

/// The status a toast reports. `Sendable` so it can cross the OCRProvider → ToastPresenter
/// (actor → MainActor) boundary.
enum ToastStyle: Sendable {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let text), .failure(let text): return text
        }
    }

    var iconName: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .success: return .green
        case .failure: return .red
        }
    }
}

/// A compact status pill: an SF Symbol icon next to a single line of text.
struct ToastView: View {
    let style: ToastStyle

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: style.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.iconColor)
            Text(verbatim: style.message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .fixedSize()
    }
}
```

- [ ] **Step 2: Build to verify the package compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/ToastView.swift
git commit -m "feat(ocr): add ToastView and ToastStyle"
```

---

## Task 7: ToastPresenter (toast window)

**Files:**
- Create: `Sources/AnyDoor/Views/ToastPresenter.swift`

- [ ] **Step 1: Implement ToastPresenter**

Create `Sources/AnyDoor/Views/ToastPresenter.swift`:

```swift
import AppKit
import SwiftUI

/// Owns a single borderless toast window shown at the bottom-center of the screen.
/// `show(_:)` is the only public entry point; the toast auto-dismisses after ~1s.
@MainActor
final class ToastPresenter {
    static let shared = ToastPresenter()

    private let panel: ToastPanel
    private let hostingController: NSHostingController<ToastView>
    private var dismissTask: Task<Void, Never>?

    private init() {
        let controller = NSHostingController(rootView: ToastView(style: .success("")))
        controller.sizingOptions = [.preferredContentSize]
        self.hostingController = controller

        let panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.contentViewController = controller
        self.panel = panel
    }

    /// Show a toast. A new call replaces the current toast in place and resets the timer.
    func show(_ style: ToastStyle) {
        dismissTask?.cancel()

        hostingController.rootView = ToastView(style: style)
        hostingController.view.layoutSubtreeIfNeeded()
        let size = hostingController.view.fittingSize
        if size.width > 0 && size.height > 0 {
            panel.setContentSize(size)
        }
        positionPanel(size: panel.frame.size)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // hold 1.0s
            guard !Task.isCancelled else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            panel.orderOut(nil)
        }
    }

    /// Bottom-center of the screen containing the mouse cursor (fallback: main screen),
    /// clear of the Dock.
    private func positionPanel(size: NSSize) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let originX = visible.midX - size.width / 2
        let originY = visible.minY + 120
        panel.setFrameOrigin(NSPoint(x: originX, y: originY))
    }
}

/// Borderless panel that never takes focus — the toast is purely informational.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
```

- [ ] **Step 2: Build to verify the package compiles**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/ToastPresenter.swift
git commit -m "feat(ocr): add ToastPresenter toast window"
```

---

## Task 8: OCRProvider (orchestration)

**Files:**
- Create: `Sources/AnyDoor/Services/Providers/OCRProvider.swift`

- [ ] **Step 1: Implement OCRProvider**

Create `Sources/AnyDoor/Services/Providers/OCRProvider.swift`:

```swift
import AppKit
import Foundation

/// Captures a screen region, recognizes its text with Vision, copies the text to
/// the clipboard, and shows a bottom-center toast reporting the outcome.
///
/// Every error is absorbed and mapped to a toast — `run()` never propagates.
actor OCRProvider: ActionProvider {
    let itemKey: BuiltinItem = .ocr

    var permission: PermissionStatus { .notRequired }

    func run() async {
        do {
            guard let image = try await RegionCapture.captureRegion() else {
                return // user cancelled — silent, no toast
            }
            let lines = try await TextRecognizer.recognize(image)
            guard !lines.isEmpty else {
                await ToastPresenter.shared.show(.failure("未识别到文字"))
                return
            }
            let text = lines.joined(separator: "\n")
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

- [ ] **Step 2: Build to verify the package compiles**

Run: `swift build`
Expected: `Build complete!` `OCRProvider.run()` is non-throwing; it satisfies the `ActionProvider` requirement `func run() async throws` (a non-throwing body satisfies a throwing requirement).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Providers/OCRProvider.swift
git commit -m "feat(ocr): add OCRProvider orchestrating capture, recognition, and toast"
```

---

## Task 9: Wire OCRProvider into AppDelegate + full verification

**Files:**
- Modify: `Sources/AnyDoor/AppDelegate.swift`

- [ ] **Step 1: Register the provider**

In `Sources/AnyDoor/AppDelegate.swift`, add `OCRProvider()` to the `providers` array. It is the last entry, after `KeyboardLockProvider()`:

```swift
            FlushDNSProvider(),
            KeyboardLockProvider(),
            OCRProvider(),
        ]
```

- [ ] **Step 2: Build the whole package**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests pass — `ShellRunnerTests`, `TextRecognizerTests`, `BuiltinItemTests` (with the new `.ocr` cases), `PanelStoreTests` (with `testRunDropsOverlappingCallForSameItem`), and every pre-existing test.

- [ ] **Step 4: Manual verification — happy path**

Run: `swift run AnyDoor`

Then, in the running app:
1. Grant Accessibility permission if prompted (System Settings → Privacy & Security → Accessibility).
2. Open the menu bar panel — confirm a "屏幕取词" row appears (an action row with the `text.viewfinder` icon). On an existing install it is at the bottom of the panel; on a fresh data store it is just after "截图到剪贴板".
3. Click the "屏幕取词" row. The native selection crosshair appears.
4. Drag a rectangle over some on-screen text (mix Chinese + English if possible).
5. Confirm: a green-check toast "已复制到剪贴板" appears at the bottom-center of the screen and fades out after ~1 second.
6. Paste (⌘V) into any text field and confirm the recognized text matches the selected region, with line breaks between blocks.

- [ ] **Step 5: Manual verification — edge cases**

1. **Cancel:** Trigger "屏幕取词", then press Esc. Confirm nothing happens — no toast, clipboard unchanged.
2. **No text:** Trigger "屏幕取词" and select a blank area (e.g. empty desktop). Confirm a red-x toast "未识别到文字" appears and the clipboard is unchanged.
3. **Slow selection:** Trigger "屏幕取词" and wait more than 5 seconds before completing the drag. Confirm the selection is NOT cancelled (the ShellRunner watchdog no longer fires).
4. **Hotkey:** Open Settings → 面板 tab, record a hotkey for "屏幕取词", close Settings, and trigger that hotkey. Confirm the selection UI appears and the flow works.
5. **Rapid double-trigger:** Press the OCR hotkey twice in quick succession. Confirm only one selection crosshair appears (the in-flight guard drops the second).
6. **Screenshot regression:** Trigger the existing "截图到剪贴板" action and confirm it still works, including a selection that takes more than 5 seconds.

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/AppDelegate.swift
git commit -m "feat(ocr): register OCRProvider in the provider registry"
```

---

## Self-Review Checklist (completed during plan authoring)

- **Spec coverage:** capture (`RegionCapture`, Task 5), recognition (`TextRecognizer`, Task 4), clipboard write + toast (`OCRProvider`, Task 8), toast window (`ToastPresenter`/`ToastView`, Tasks 6-7), `BuiltinItem.ocr` (Task 2), provider registration (Task 9), `ShellRunner` optional timeout + `ScreenshotProvider` fix (Task 1), `PanelStore.run` in-flight guard (Task 3). All spec sections map to a task.
- **Panel ordering:** the spec's "no migration; existing installs append at end" decision needs no code — `BuiltinPreferenceSeeder` already does this. Covered by the manual check in Task 9 Step 4.
- **Type consistency:** `recognize(_ image: CGImage) async throws -> [String]`, `captureRegion() async throws -> CGImage?`, `ToastStyle` (`.success`/`.failure` with `String`), `ToastPresenter.shared.show(_:)`, `OCRError.imageDecodeFailed` — names are identical across all tasks that reference them.
- **No placeholders:** every step contains complete code or an exact command.
