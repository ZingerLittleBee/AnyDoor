# Interactive Scrolling Capture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the auto-scroll scrolling capture with a CleanShot X-style interactive session: a floating preview panel + Done/Cancel, manual scrolling, live stitched preview, delivered through the standard post-capture overlay.

**Architecture:** See `docs/superpowers/specs/2026-06-15-interactive-scrolling-capture-design.md`. `ScrollCaptureSession` (@MainActor) observes real `.scrollWheel` events, grabs the viewport *below its own preview window* (`LegacyScreenCapture.belowWindow`, so the session UI never lands in the shot), feeds frames to a reusable `ScrollStitchAccumulator`, and drives a `ScrollCaptureSessionWindow` (preview + toolbar) + a `ScrollViewportOutlineWindow`. The old synthetic auto-loop is removed; its pure pixel helpers are retained.

**Tech Stack:** Swift 6.2 strict concurrency, AppKit `NSPanel`/`NSEvent` monitors, SwiftUI `NSHostingView`, `LegacyScreenCapture` (synchronous CoreGraphics `CGWindowListCreateImage` via dlsym — never SCK), XCTest pure tests.

**Constraints:**
- `LegacyScreenCapture` only; the only capture call is the synchronous `belowWindow`. No SCK; no cross-isolation `await` on a `@MainActor` frame. `NSEvent` monitor + `Timer` callbacks are nonisolated → run main-actor side-effects via `MainThreadIsolation.run` (the project helper used elsewhere).
- Panels are `.nonactivatingPanel` (the target keeps scroll focus). SwiftUI buttons in such a panel receive clicks (validated by the Phase 2 capture toolbar).
- UI strings Chinese via `L(.key)`; code/comments/commits English, Conventional Commits, no co-authored/watermark lines, no leading `@`. Commit locally; never push.

**Ordering (every boundary builds):** additive helpers/accumulator/strings/windows first, then the session controller, then switch the coordinator to it, then strip the now-unused engine auto-loop.

---

## File Structure

- Modify `Sources/AnyDoor/Services/Capture/LegacyScreenCapture.swift` — `belowWindow(_:bounds:)`.
- Create `Sources/AnyDoor/Services/Capture/ScrollStitchAccumulator.swift`.
- Create `Tests/AnyDoorTests/ScrollStitchAccumulatorTests.swift`.
- Modify `Sources/AnyDoor/Utilities/L10n.swift` + `Sources/AnyDoor/Resources/Localizable.xcstrings` — `capture.scroll.*` keys.
- Create `Sources/AnyDoor/Views/Capture/ScrollViewportOutlineWindow.swift`.
- Create `Sources/AnyDoor/Views/Capture/ScrollCaptureSessionWindow.swift`.
- Create `Sources/AnyDoor/Services/Capture/ScrollCaptureSession.swift`.
- Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift` — start the session.
- Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureEngine.swift` — strip to pure helpers.
- Modify `CHANGELOG.md`.

> AppKit/session code is build-verified (no headless AppKit + capture constraints), as in prior phases. New pure tests: `ScrollStitchAccumulatorTests`. `ScrollStitcherTests` / `ScrollCaptureEngineTests` stay green.

---

## Task 1: `LegacyScreenCapture.belowWindow(_:bounds:)`

**Files:** Modify `Sources/AnyDoor/Services/Capture/LegacyScreenCapture.swift`

- [ ] **Step 1: Add the option constant + the grab function**

After `private static let kImageBestResolution` add:

```swift
private static let kOptionOnScreenBelowWindow: UInt32 = 1 << 2  // .optionOnScreenBelowWindow
```

After `window(_:)` add:

```swift
/// A still of everything on screen *below* `windowID`, clipped to `bounds`
/// (CG global coordinates, top-left origin). Scrolling capture uses this to grab
/// the viewport without the session's own preview/outline windows in the shot.
static func belowWindow(_ windowID: CGWindowID, bounds: CGRect) -> CGImage? {
    windowFn?(bounds, kOptionOnScreenBelowWindow, windowID, kImageBestResolution)?.takeRetainedValue()
}
```

- [ ] **Step 2: Build + test**

Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/LegacyScreenCapture.swift
git commit -m "feat(capture): add a below-window region grab for scrolling capture"
```

---

## Task 2: `ScrollStitchAccumulator` + tests

**Files:**
- Create `Sources/AnyDoor/Services/Capture/ScrollStitchAccumulator.swift`
- Create `Tests/AnyDoorTests/ScrollStitchAccumulatorTests.swift`

- [ ] **Step 1: Write the failing tests** (reuse the synthetic-image helpers’ approach from `ScrollCaptureEngineTests`)

```swift
import XCTest
import CoreGraphics
@testable import AnyDoor

final class ScrollStitchAccumulatorTests: XCTestCase {
    private func image(width: Int, colors: [(UInt8, UInt8, UInt8)]) -> CGImage {
        let h = colors.count, bpr = width * 4
        var data = [UInt8](repeating: 0, count: bpr * h)
        for row in 0..<h {
            let (r, g, b) = colors[row]
            for x in 0..<width {
                let o = row * bpr + x * 4
                data[o] = r; data[o + 1] = g; data[o + 2] = b; data[o + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(data) as CFData)!
        return CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func distinctColors(_ n: Int, from start: Int = 0) -> [(UInt8, UInt8, UInt8)] {
        (0..<n).map { i in let v = i + start; return (UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0) }
    }

    @MainActor func testFirstFrameSeeds() {
        let acc = ScrollStitchAccumulator()
        XCTAssertNil(acc.composite())
        XCTAssertEqual(acc.totalHeight, 0)
        XCTAssertTrue(acc.ingest(image(width: 4, colors: distinctColors(60))))
        XCTAssertEqual(acc.sliceCount, 1)
        XCTAssertEqual(acc.totalHeight, 60)
        XCTAssertEqual(acc.composite()?.height, 60)
    }

    @MainActor func testScrolledFrameAppendsOnlyNewRows() {
        let tall = distinctColors(120)
        let acc = ScrollStitchAccumulator()
        _ = acc.ingest(image(width: 4, colors: Array(tall[0..<60])))
        XCTAssertTrue(acc.ingest(image(width: 4, colors: Array(tall[20..<80])))) // scrolled 20
        XCTAssertEqual(acc.totalHeight, 80)        // 60 + 20 new rows
        XCTAssertEqual(acc.composite()?.height, 80)
    }

    @MainActor func testIdenticalFrameAppendsNothing() {
        let frame = distinctColors(60)
        let acc = ScrollStitchAccumulator()
        _ = acc.ingest(image(width: 4, colors: frame))
        XCTAssertFalse(acc.ingest(image(width: 4, colors: frame)))
        XCTAssertEqual(acc.totalHeight, 60)
    }
}
```

Run: `swift test --filter ScrollStitchAccumulatorTests` → FAIL (no such type).

- [ ] **Step 2: Implement** (ports the old `ScrollCaptureEngine.advance()` math)

```swift
import CoreGraphics

/// Running scrolling-capture stitch state, factored out of the old auto-loop so it
/// is unit-testable. The first frame seeds the stitch; later frames are aligned
/// against the previous one via `ScrollStitch.detectOverlap`, appending only the
/// newly revealed bottom rows. Pixel space (top-left rows), display scale agnostic.
@MainActor
final class ScrollStitchAccumulator {
    private let policy: ScrollCapturePolicy
    private var slices: [(image: CGImage, height: Int)] = []
    private var prevSig: [ScrollStitch.RowSig] = []
    private var viewportPx = 0
    private var minOverlap = 0
    private var lastDelta: Int?

    init(policy: ScrollCapturePolicy = ScrollCapturePolicy()) { self.policy = policy }

    var sliceCount: Int { slices.count }
    var totalHeight: Int { slices.reduce(0) { $0 + $1.height } }

    /// Ingest a freshly grabbed viewport frame. Returns true when rows were appended.
    @discardableResult
    func ingest(_ frame: CGImage) -> Bool {
        guard let sig = ScrollCaptureEngine.rowSignatures(of: frame) else { return false }
        if slices.isEmpty {
            slices = [(frame, frame.height)]
            prevSig = sig
            viewportPx = frame.height
            minOverlap = min(policy.minOverlapRows(viewportHeight: viewportPx), viewportPx)
            return true
        }
        guard let m = ScrollStitch.detectOverlap(prev: prevSig, cur: sig,
                                                 minOverlap: minOverlap,
                                                 minMatchRatio: policy.minMatchRatio,
                                                 expected: lastDelta),
              m.delta > 0 else { return false }
        let rect = CGRect(x: 0, y: frame.height - m.delta, width: frame.width, height: m.delta)
        guard let slice = frame.cropping(to: rect) else { return false }
        slices.append((slice, m.delta))
        prevSig = sig
        lastDelta = m.delta
        return true
    }

    /// The stitched image so far (nil before the first frame).
    func composite() -> CGImage? { ScrollCaptureEngine.composite(slices: slices) }
}
```

- [ ] **Step 3: Run tests → pass; build**

Run: `swift test --filter ScrollStitchAccumulatorTests` → PASS (3 tests).
Run: `swift build 2>&1 | tail -3` → Build complete!

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScrollStitchAccumulator.swift Tests/AnyDoorTests/ScrollStitchAccumulatorTests.swift
git commit -m "feat(capture): add ScrollStitchAccumulator for live scroll stitching"
```

---

## Task 3: Localization keys `capture.scroll.*`

**Files:**
- Modify `Sources/AnyDoor/Utilities/L10n.swift`
- Modify `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add `L10n.Key` cases** (next to the other `captureOverlay*` cases):

```swift
case captureScrollTitle = "capture.scroll.title"
case captureScrollDone = "capture.scroll.done"
case captureScrollCancel = "capture.scroll.cancel"
case captureScrollCaptured = "capture.scroll.captured"
```

- [ ] **Step 2: Add the four entries to `Localizable.xcstrings`**, mirroring the structure of an existing `capture.*` entry (e.g. `capture.overlay.save`): each key maps to `localizations` with `en` and `zh-Hans` `stringUnit` values:
  - `capture.scroll.title` → en `"Scrolling Capture"`, zh-Hans `"滚动截图"`
  - `capture.scroll.done` → en `"Done"`, zh-Hans `"完成"`
  - `capture.scroll.cancel` → en `"Cancel"`, zh-Hans `"取消"`
  - `capture.scroll.captured` → en `"Captured %d px"`, zh-Hans `"已捕获 %d px"`

> The `%d` arg is an `Int`; `L(.captureScrollCaptured, n)` formats it (the global `L(_:_,:)` takes `CVarArg...`). Keep `%d` identical in both locales.

- [ ] **Step 3: Build (compiles the catalog via the build-tool plugin)**

Run: `swift build 2>&1 | tail -3` → Build complete!
Verify resolution: a quick test or just trust the build; the plugin fails the build on malformed xcstrings.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(capture): add localization keys for the scrolling capture session"
```

---

## Task 4: `ScrollViewportOutlineWindow`

**Files:** Create `Sources/AnyDoor/Views/Capture/ScrollViewportOutlineWindow.swift`

- [ ] **Step 1: Implement** a click-through border panel at the viewport:

```swift
import AppKit

/// A click-through, transparent border drawn around the scrolling-capture
/// viewport so the user knows where to scroll. Ordered above the preview panel so
/// the session's below-preview grab excludes it from the stitched image.
@MainActor
final class ScrollViewportOutlineWindow {
    private var panel: NSPanel?

    func present(frame: CGRect) {
        dismiss()
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = OutlineView(frame: NSRect(origin: .zero, size: frame.size))
        p.orderFrontRegardless()
        panel = p
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(bounds.insetBy(dx: 1, dy: 1))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3` → Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/ScrollViewportOutlineWindow.swift
git commit -m "feat(capture): add the scrolling-capture viewport outline window"
```

---

## Task 5: `ScrollCaptureSessionWindow` (preview + Done/Cancel)

**Files:** Create `Sources/AnyDoor/Views/Capture/ScrollCaptureSessionWindow.swift`

Modeled on `RecordingControlsWindow`: an `@MainActor` class owning an `NSPanel` hosting a SwiftUI view bound to an `@Observable` model.

- [ ] **Step 1: Implement**

```swift
import AppKit
import SwiftUI

/// Floating preview + Done/Cancel for an interactive scrolling capture. The
/// preview grows and auto-scrolls to the bottom as frames are stitched. The panel
/// is non-activating so the target window keeps scroll focus; the session grabs
/// the viewport *below* this panel so it never appears in the stitched image.
@MainActor
final class ScrollCaptureSessionWindow {
    private var panel: NSPanel?
    private let model = ScrollCaptureSessionModel()

    /// 0 until presented; the window number the session passes to the below-window grab.
    var windowNumber: Int { panel?.windowNumber ?? 0 }

    func present(viewport: CGRect, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        model.image = nil
        model.heightPx = 0
        model.onDone = onDone
        model.onCancel = onCancel
        guard panel == nil else { return }

        let size = CGSize(width: 320, height: 440)
        // Bottom-right of the viewport's display (does not matter for correctness —
        // the grab excludes this window — but keep it off the viewport visually).
        let screen = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: viewport.midX, y: viewport.midY)) }
                      ?? NSScreen.main)?.visibleFrame ?? .zero
        let origin = CGPoint(x: screen.maxX - size.width - 16, y: screen.minY + 16)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: ScrollCaptureSessionView(model: model))
        p.orderFrontRegardless()
        panel = p
    }

    func updatePreview(_ image: NSImage, heightPx: Int) {
        model.image = image
        model.heightPx = heightPx
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

@MainActor
@Observable
final class ScrollCaptureSessionModel {
    var image: NSImage?
    var heightPx: Int = 0
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
}

private struct ScrollCaptureSessionView: View {
    @Bindable var model: ScrollCaptureSessionModel

    var body: some View {
        VStack(spacing: 10) {
            Text(L(.captureScrollTitle))
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if let image = model.image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                        } else {
                            Color.clear.frame(height: 1)
                        }
                    }
                    .id("bottom")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: model.heightPx) { _, _ in
                    withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            Text(L(.captureScrollCaptured, model.heightPx))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button(L(.captureScrollCancel)) { model.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L(.captureScrollDone)) { model.onDone?() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 320, height: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
```

> `keyboardShortcut(.cancelAction/.defaultAction)` only fire while the panel is key; since it is non-activating these are best-effort. Esc-to-cancel is also handled by the session's global key monitor (Task 6), and Done is primarily the button click.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3` → Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/ScrollCaptureSessionWindow.swift
git commit -m "feat(capture): add the scrolling-capture preview + Done/Cancel window"
```

---

## Task 6: `ScrollCaptureSession` controller

**Files:** Create `Sources/AnyDoor/Services/Capture/ScrollCaptureSession.swift`

- [ ] **Step 1: Implement** the controller (monitors are nonisolated → side-effects via `MainThreadIsolation.run`):

```swift
import AppKit
import CoreGraphics

/// Interactive scrolling capture: shows a preview + Done/Cancel, observes real
/// scroll events, grabs the viewport (below its own preview window so the session
/// UI is never in the shot), stitches live, and delivers via the output policy.
/// @MainActor, monitor/timer-driven; the only capture is the synchronous
/// `LegacyScreenCapture.belowWindow`, so no cross-isolation await occurs.
@MainActor
final class ScrollCaptureSession {
    static let shared = ScrollCaptureSession()

    private let previewWindow = ScrollCaptureSessionWindow()
    private let outlineWindow = ScrollViewportOutlineWindow()
    private var accumulator: ScrollStitchAccumulator?
    private var viewport: CGRect = .zero
    private var primaryMaxY: CGFloat = 0
    private var scrollMonitor: Any?
    private var keyMonitor: Any?
    private var trailingTimer: Timer?
    private var lastGrab = Date.distantPast
    private var onEnd: (() -> Void)?
    private var active = false

    private init() {}

    /// Begin a session for `viewport` (global AppKit coords). `onEnd` fires once
    /// when the session finishes (Done or Cancel) so the caller can release state.
    func start(viewport: CGRect, onEnd: @escaping () -> Void) {
        guard !active else { onEnd(); return }
        active = true
        self.viewport = viewport
        self.onEnd = onEnd
        self.accumulator = ScrollStitchAccumulator()
        self.primaryMaxY = NSScreen.screens.first?.frame.maxY ?? viewport.maxY

        // Preview first, then outline ordered above it, so the below-preview grab
        // excludes both session windows.
        previewWindow.present(viewport: viewport,
            onDone: { [weak self] in self?.finishSession(deliver: true) },
            onCancel: { [weak self] in self?.finishSession(deliver: false) })
        outlineWindow.present(frame: viewport)

        grabAndIngest()   // seed with the first frame

        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            MainThreadIsolation.run { self?.handleScroll() }
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = event.keyCode
            MainThreadIsolation.run { if code == 53 { self?.finishSession(deliver: false) } }
        }
    }

    private func handleScroll() {
        guard active else { return }
        if Date().timeIntervalSince(lastGrab) >= 0.06 { grabAndIngest() }
        // Trailing grab to capture the resting position after the scroll stops.
        trailingTimer?.invalidate()
        trailingTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: false) { [weak self] _ in
            MainThreadIsolation.run { self?.grabAndIngest() }
        }
    }

    private func grabAndIngest() {
        guard active, let acc = accumulator, previewWindow.windowNumber > 0 else { return }
        lastGrab = Date()
        let cg = CGRect(x: viewport.minX, y: primaryMaxY - viewport.maxY,
                        width: viewport.width, height: viewport.height)
        guard let frame = LegacyScreenCapture.belowWindow(CGWindowID(previewWindow.windowNumber), bounds: cg) else { return }
        if acc.ingest(frame), let img = acc.composite() {
            previewWindow.updatePreview(NSImage(cgImage: img, size: .zero), heightPx: acc.totalHeight)
        }
    }

    private func finishSession(deliver: Bool) {
        guard active else { return }
        active = false
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil; keyMonitor = nil
        trailingTimer?.invalidate(); trailingTimer = nil

        let image = deliver ? accumulator?.composite() : nil
        accumulator = nil
        outlineWindow.dismiss()
        previewWindow.dismiss()

        if deliver {
            if let image {
                CaptureCoordinator.shared.deliverCapturedImage(image, anchor: viewport)
            } else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            }
        }
        let cb = onEnd; onEnd = nil; cb?()
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3` → Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScrollCaptureSession.swift
git commit -m "feat(capture): add the interactive scrolling-capture session controller"
```

---

## Task 7: Route `ScrollCaptureCoordinator` to the session

**Files:** Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift`

Replace the engine usage with the session. Keep the permission gate, the `inFlight`
guard (released when the session ends), and the region-handoff / standalone-overlay split.

- [ ] **Step 1: Rewrite the coordinator body**

```swift
import AppKit
import CoreGraphics

/// Orchestrates a scrolling capture: permission check -> resolve the viewport
/// (region handoff from the toolbar, or the built-in selection overlay) ->
/// hand off to the interactive `ScrollCaptureSession`. `@MainActor`, callback-based.
@MainActor
final class ScrollCaptureCoordinator {
    static let shared = ScrollCaptureCoordinator()
    private let selectionOverlay = SelectionOverlayWindow()
    private var inFlight = false
    private init() {}

    /// Entry point. `region` (global AppKit coords) skips the built-in viewport
    /// selection (used by the unified capture toolbar). `nil` presents the overlay
    /// to let the user pick a viewport.
    func capture(region: CGRect? = nil) {
        guard !inFlight else { return }
        guard ScreenCapturePermission.ensureGranted() else {
            ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
            ScreenCapturePermission.openSettings()
            return
        }
        inFlight = true

        if let region { startSession(viewport: region); return }

        var frozen: [CGDirectDisplayID: CGImage] = [:]
        var targets: [TargetDisplay] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID, let img = LegacyScreenCapture.display(id) else { continue }
            targets.append(TargetDisplay(id: id, frame: screen.frame, backingScale: screen.backingScaleFactor))
            frozen[id] = img
        }
        guard !targets.isEmpty else { finish(); return }

        selectionOverlay.present(targets: targets, mode: .region, frozen: frozen) { [weak self] result in
            guard let self else { return }
            guard case let .region(_, rect) = result else { self.finish(); return }
            self.startSession(viewport: rect)
        }
    }

    private func startSession(viewport: CGRect) {
        // Let any selection overlay fully clear before the session's first grab.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            ScrollCaptureSession.shared.start(viewport: viewport) { [weak self] in self?.finish() }
        }
    }

    private func finish() { inFlight = false }
}
```

> This removes `private let engine = ScrollCaptureEngine()` and the `runEngine` helper added in the toolbar Phase 3. The `nil` standalone path keeps presenting the selection overlay; only the post-selection step changed (session instead of auto-engine).

- [ ] **Step 2: Build + test**

Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift
git commit -m "feat(capture): drive scrolling capture through the interactive session"
```

---

## Task 8: Strip `ScrollCaptureEngine` to pure helpers

**Files:** Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureEngine.swift`

The auto-loop is now unreferenced; keep only the static pixel helpers the
accumulator + tests use.

- [ ] **Step 1: Confirm no remaining references to the instance API**

Run: `grep -rn "ScrollCaptureEngine(" Sources Tests` → no matches.
Run: `grep -rn "ScrollCaptureEngine\." Sources Tests` → only `.rowSignatures` / `.composite` (statics).

- [ ] **Step 2: Replace the file** with an `enum` holding only the statics (copy the existing bodies verbatim — `rowSignatures`, `fnv1a`, `composite`):

```swift
import CoreGraphics

/// Pure pixel helpers for scrolling capture: per-row fingerprints and top-to-bottom
/// compositing. (The live capture loop now lives in `ScrollCaptureSession` +
/// `ScrollStitchAccumulator`; these synchronous helpers are shared by both and the
/// unit tests.)
enum ScrollCaptureEngine {
    /// Top-to-bottom per-row fingerprints of `image` (RGBA8, one FNV-1a hash/row).
    nonisolated static func rowSignatures(of image: CGImage) -> [ScrollStitch.RowSig]? {
        // ... copy the existing implementation verbatim ...
    }

    nonisolated private static func fnv1a(_ ptr: UnsafeRawPointer, _ count: Int) -> ScrollStitch.RowSig {
        // ... copy verbatim ...
    }

    /// Stacks pixel slices top-to-bottom into one tall image.
    nonisolated static func composite(slices: [(image: CGImage, height: Int)]) -> CGImage? {
        // ... copy verbatim ...
    }
}
```

> Delete the instance state and the `capture` / `scheduleStep` / `advance` /
> `postScroll` / `finish` / `finishStitched` / `grabViewport` / `cgPoint(fromAppKit:)`
> methods. `ScrollCapturePolicy` and `ScrollStitch` are untouched (still used by the
> accumulator).

- [ ] **Step 3: Build + full test** (`ScrollCaptureEngineTests` exercises only the statics, so it stays green)

Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScrollCaptureEngine.swift
git commit -m "refactor(capture): reduce ScrollCaptureEngine to shared pixel helpers"
```

---

## Task 9: Changelog + verification

**Files:** Modify `CHANGELOG.md`

- [ ] **Step 1: Add an entry** under `## [Unreleased]` → `### Changed`:

```markdown
- Scrolling capture is now interactive (CleanShot X style): after selecting the
  region, a floating preview with Done/Cancel appears and you scroll the target
  yourself while the long image is stitched live, instead of an unreliable
  automatic scroll. The session's own windows are excluded from the capture.
```

- [ ] **Step 2: Build + full test**

Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(capture): record interactive scrolling capture in the changelog"
```

- [ ] **Step 4: Manual verification (user-run, `swift run AnyDoor`)**

1. "截图菜单" → select a region over a scrollable view → click "滚动".
2. Selection overlay clears; the viewport outline + the preview panel (Done/Cancel) appear.
3. Scroll the target (trackpad/wheel) — the preview grows and auto-scrolls to the bottom; "已捕获 N px" climbs.
4. Click **Done** → the standard overlay appears with the tall stitched image (copy/save/edit/pin/OCR); it enters history.
5. Re-run and click **Cancel** (or Esc) → nothing is saved.
6. Inspect the saved image — the preview panel, outline, and toolbar are **not** in it.
7. The standalone "滚动截图" builtin shows the same session after its own region selection.

---

## Self-Review notes

- **Spec coverage:** manual scroll session (§6.4 ✓ T6), preview + Done/Cancel (§6.5 ✓ T5), outline (§6.6 ✓ T4), exclude own UI via below-window grab (§6.1 ✓ T1, used in T6), reusable stitch (§6.3 ✓ T2), both entries (§6.7 ✓ T7), strip auto-loop (§6.2 ✓ T8), standard Done destination (✓ T6 deliverCapturedImage).
- **Type/dep consistency:** `belowWindow` (T1) used by the session (T6); `ScrollStitchAccumulator` (T2) used by the session (T6); the two windows (T4/T5) owned by the session (T6); `ScrollCaptureSession.start(viewport:onEnd:)` called by the coordinator (T7); engine statics (T8) used by the accumulator (T2) and tests.
- **Green-at-every-boundary:** T1-T6 additive; T7 switches the coordinator off the engine; T8 strips the now-unreferenced engine instance.
- **Constraints:** only `LegacyScreenCapture` (synchronous); monitor/timer callbacks hop via `MainThreadIsolation.run`; the session's only capture is `belowWindow`; non-activating panels keep target scroll focus.
- **Risks (validate manually):** below-window z-order excludes the session UI; fast scrolls drop (not corrupt) frames; preview re-composite cost is acceptable for typical heights.
</content>
