# Capture Selection — Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the attached capture toolbar's **scrolling** and **recording** buttons act on the *current selection* instead of starting their own separate selection — by adding optional pre-selected-region entries to `ScrollCaptureCoordinator` / `RecordingCoordinator`, extending `SelectionResult`, introducing `CaptureToolType`, and growing the toolbar from 3 to 5 buttons (region / window / fullscreen / scrolling / recording).

**Architecture:** The unified overlay already owns a selection rectangle (global AppKit coords). Clicking scrolling/recording tears the frozen overlay down and hands the rect to the respective live-capture coordinator, which now has a "skip my own selection, use this region" entry. Both coordinators already drive `SelectionOverlayWindow` + already contain the post-selection logic, so this is an *extraction* (factor out the post-selection body) plus an additive region entry — not a rewrite.

**Tech Stack:** Swift 6.2 strict concurrency, AppKit/SwiftUI, `LegacyScreenCapture` (synchronous CoreGraphics — never SCK), `AVCaptureScreenInput` (recording engine, not SCK), `ScrollCaptureEngine` (warp+scroll+grab), XCTest pure tests.

**Scope (per spec §7.9 / §9 Phase 3):**
- `ScrollCaptureCoordinator.capture(region: CGRect? = nil)` — `nil` keeps today's flow; a region skips the overlay and uses that viewport.
- `RecordingCoordinator.record(rect: CGRect)` — record a pre-selected region (derives display + cropRect itself).
- `SelectionResult.scrolling(rect:)` / `.recording(rect:)`; `CaptureCoordinator.handle` routes them.
- `CaptureToolType` (region/window/fullscreen/scrolling/recording); toolbar renders all five; the overlay's `toolbarPicked` dispatches scrolling/recording via new `onScrolling`/`onRecording` callbacks carrying the current rect in global AppKit coords.

**Ordering rationale (every task boundary stays green):** coordinators first (additive, default params), then `SelectionResult` + `handle` (exhaustive switch updated together with the coordinator calls it needs), then the toolbar/view migration that finally *produces* the new results. Nothing emits `.scrolling`/`.recording` until Task 4, by which point both the producer plumbing (coordinators, Tasks 1-2) and the consumer (`handle`, Task 3) exist.

**Constraints to preserve:**
- No `await` of a cross-isolation async on a `@MainActor` frame in the still-capture/scroll path (executor-corruption bug). New code stays callback / synchronous; `Task.sleep` (resumes on main) is allowed, as in the existing coordinators.
- `LegacyScreenCapture` only for stills; recording stays on `AVCaptureScreenInput`; scrolling stays on `ScrollCaptureEngine`. Do not introduce SCK.
- UI strings Chinese via `L(.key)` (reuse `captureModeBarScrolling` / `captureModeBarRecording`); code/comments/commits English, Conventional Commits, no co-authored/watermark lines, no leading `@`. Commit locally; never push.

---

## File Structure

- Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift` — `capture(region:)` + extracted `runEngine`.
- Modify `Sources/AnyDoor/Services/Recording/RecordingCoordinator.swift` — `record(rect:)` + extracted `beginRecording(globalRect:)`.
- Modify `Sources/AnyDoor/Services/Capture/CaptureTypes.swift` — `SelectionResult.scrolling`/`.recording`; new `CaptureToolType`.
- Modify `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift` — `handle` routes scrolling/recording.
- Modify `Sources/AnyDoor/Services/Capture/CaptureToolbarPolicy.swift` — `tools: [CaptureToolType]` (5) + symbol/labelKey over `CaptureToolType`.
- Modify `Tests/AnyDoorTests/CaptureToolbarPolicyTests.swift` — expect 5 tools.
- Modify `Sources/AnyDoor/Views/Capture/CaptureSelectionToolbar.swift` — emit `CaptureToolType`, render from `tools`.
- Modify `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` — `onScrolling`/`onRecording`; `toolbarPicked(_:CaptureToolType)`; wire `present`.
- Modify `CHANGELOG.md`.

> AppKit/coordinator changes are build-verified (no headless AppKit + the SCK/executor constraint), as in Phases 1-2. The only pure test updated is `CaptureToolbarPolicyTests`.

---

## Task 1: `ScrollCaptureCoordinator.capture(region:)` region handoff

**Files:** Modify `Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift`

- [ ] **Step 1: Extract the post-selection body and add the region entry**

Replace `capture()` and add `runEngine`:

```swift
/// Entry point. `region` (global AppKit coords) skips the built-in viewport
/// selection — used by the unified capture toolbar, which already has a
/// selection. `nil` keeps the standalone flow: freeze displays, let the user
/// pick a viewport, then scroll+stitch.
func capture(region: CGRect? = nil) {
    guard !inFlight else { return }
    guard ScreenCapturePermission.ensureGranted() else {
        ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
        ScreenCapturePermission.openSettings()
        return
    }
    inFlight = true

    if let region {
        runEngine(viewport: region)
        return
    }

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
        self.runEngine(viewport: rect)
    }
}

/// Derive the display under the viewport, let the screen clear, then scroll+stitch.
private func runEngine(viewport rect: CGRect) {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let display = NSScreen.screens.first(where: { $0.frame.contains(center) })
        ?? NSScreen.screenUnderMouse ?? NSScreen.main
    guard let display, let id = display.displayID else { finish(); return }
    let target = TargetDisplay(id: id, frame: display.frame, backingScale: display.backingScaleFactor)
    // Let the overlay (built-in or the unified toolbar's) fully clear before the
    // first grab, so the stitched image never includes overlay chrome.
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(140))
        self.engine.capture(viewport: rect, display: target) { [weak self] image in
            guard let self else { return }
            if let image {
                CaptureCoordinator.shared.deliverCapturedImage(image, anchor: rect)
            } else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
            }
            self.finish()
        }
    }
}
```

> The standalone overlay path previously derived `display` from `targets`; `runEngine` re-derives it from `NSScreen.screens` so both paths share one code path. Behavior is unchanged for the `nil` case (same viewport, same 140 ms clear, same delivery).

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete! (the existing `ScrollCaptureCoordinator.shared.capture()` call site in `CaptureProviders.swift` still compiles — `region` defaults to `nil`.)

- [ ] **Step 3: Full test (no regressions)**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/ScrollCaptureCoordinator.swift
git commit -m "feat(capture): let scrolling capture accept a pre-selected region"
```

---

## Task 2: `RecordingCoordinator.record(rect:)` region handoff

**Files:** Modify `Sources/AnyDoor/Services/Recording/RecordingCoordinator.swift`

- [ ] **Step 1: Add the pre-selected-region entry + extract a shared helper**

Add a new entry near `record(region:)`:

```swift
/// Record a pre-selected region (global AppKit coords) — used by the unified
/// capture toolbar. Gates the same permissions as `record(region:)`, then starts
/// recording without presenting its own selection.
func record(rect: CGRect) {
    guard state == .idle else { return }
    guard ScreenCapturePermission.ensureGranted() else {
        ToastPresenter.shared.show(.failure(L(.toastScreenCapturePermissionDenied)))
        ScreenCapturePermission.openSettings()
        return
    }
    ensureMediaPermissions(mic: settings.includeMicrophone, camera: settings.includeCamera) { [weak self] in
        self?.beginRecording(globalRect: rect)
    }
}
```

Add the shared helper that turns a global rect into a display + cropRect:

```swift
/// Map a global AppKit rect to its display + `AVCaptureScreenInput.cropRect`
/// (the display's coordinate space, lower-left origin, points) and begin.
private func beginRecording(globalRect rect: CGRect) {
    guard let screen = NSScreen.screens.first(where: {
              $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY))
          }) ?? NSScreen.main,
          let id = screen.displayID else { finishIdle(); return }
    let crop = CGRect(x: rect.minX - screen.frame.minX, y: rect.minY - screen.frame.minY,
                      width: rect.width, height: rect.height)
    beginRecording(displayID: id, cropRect: crop)
}
```

Refactor `beginRegionSelection`'s completion to reuse it (DRY) — replace the body after the `.region` guard with:

```swift
selectionOverlay.present(targets: targets, mode: .region, frozen: frozen) { [weak self] result in
    guard let self else { return }
    guard case let .region(_, rect) = result else { self.finishIdle(); return }
    self.beginRecording(globalRect: rect)
}
```

> This removes the now-duplicated screen-derivation + crop math from `beginRegionSelection` (it lived inline there). Confirm against the current file (`beginRegionSelection` around lines 77-97) and delete the inline duplicate.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete!

- [ ] **Step 3: Full test**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Services/Recording/RecordingCoordinator.swift
git commit -m "feat(recording): record a pre-selected region without its own selection"
```

---

## Task 3: `SelectionResult.scrolling/recording` + `CaptureCoordinator.handle` routing

**Files:**
- Modify `Sources/AnyDoor/Services/Capture/CaptureTypes.swift`
- Modify `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift`

- [ ] **Step 1: Add the two result cases**

In `SelectionResult` (CaptureTypes.swift), add before `case cancelled`:

```swift
/// Scrolling capture requested on the current selection; `rect` is global
/// AppKit coords. No image — the live scroll engine grabs after the overlay clears.
case scrolling(rect: CGRect)
/// Screen recording requested on the current selection; `rect` is global AppKit coords.
case recording(rect: CGRect)
```

- [ ] **Step 2: Route them in `handle`**

In `CaptureCoordinator.handle(_:delay:)`, add the two cases (these are live captures — no countdown; release `inFlight` first, then hand off to the owning coordinator, which has its own guard):

```swift
case let .scrolling(rect):
    finish()
    ScrollCaptureCoordinator.shared.capture(region: rect)
case let .recording(rect):
    finish()
    RecordingCoordinator.shared.record(rect: rect)
```

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -3`
Expected: Build complete! (`handle`'s switch is now exhaustive again; both coordinator entries exist from Tasks 1-2. No producer emits these cases yet — that is Task 4.)

- [ ] **Step 4: Full test**

Run: `swift test 2>&1 | tail -3`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureTypes.swift Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift
git commit -m "feat(capture): route scrolling/recording selection results to their coordinators"
```

---

## Task 4: `CaptureToolType` + grow the toolbar to 5 types and emit scrolling/recording

**Files:**
- Modify `Sources/AnyDoor/Services/Capture/CaptureTypes.swift`
- Modify `Sources/AnyDoor/Services/Capture/CaptureToolbarPolicy.swift`
- Modify `Tests/AnyDoorTests/CaptureToolbarPolicyTests.swift`
- Modify `Sources/AnyDoor/Views/Capture/CaptureSelectionToolbar.swift`
- Modify `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift`

This migrates the toolbar from `CaptureMode` (3) to `CaptureToolType` (5) and wires scrolling/recording end-to-end. All five edits land together so the build stays green.

- [ ] **Step 1: Add `CaptureToolType`** to `CaptureTypes.swift`:

```swift
/// The capture types offered by the attached selection toolbar. A superset of
/// `CaptureMode`: region/window/fullscreen are still-capture modes, while
/// scrolling/recording hand the current rect to their own live coordinators.
enum CaptureToolType: String, CaseIterable, Sendable {
    case region, window, fullscreen, scrolling, recording
}
```

- [ ] **Step 2: Update the toolbar test (failing first)**

In `CaptureToolbarPolicyTests.swift`, replace the order test and keep the per-item test:

```swift
func testToolsAreTheFiveCaptureTypesInOrder() {
    XCTAssertEqual(CaptureToolbarPolicy.tools,
                   [.region, .window, .fullscreen, .scrolling, .recording])
}

@MainActor
func testEveryToolHasASymbolAndLabelKey() {
    for tool in CaptureToolbarPolicy.tools {
        XCTAssertFalse(CaptureToolbarPolicy.symbol(for: tool).isEmpty)
        XCTAssertFalse(L(CaptureToolbarPolicy.labelKey(for: tool)).isEmpty)
    }
}
```

Run: `swift test --filter CaptureToolbarPolicyTests` → FAIL (no `tools`/`CaptureToolType` overloads yet).

- [ ] **Step 3: Migrate `CaptureToolbarPolicy`** to `CaptureToolType`:

```swift
enum CaptureToolbarPolicy {
    /// Buttons rendered, left to right.
    static let tools: [CaptureToolType] = [.region, .window, .fullscreen, .scrolling, .recording]

    static func symbol(for tool: CaptureToolType) -> String {
        switch tool {
        case .region:     return "rectangle.dashed"
        case .window:     return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        case .scrolling:  return "arrow.down.to.line"
        case .recording:  return "record.circle"
        }
    }

    static func labelKey(for tool: CaptureToolType) -> L10n.Key {
        switch tool {
        case .region:     return .captureModeBarRegion
        case .window:     return .captureModeBarWindow
        case .fullscreen: return .captureModeBarFullscreen
        case .scrolling:  return .captureModeBarScrolling
        case .recording:  return .captureModeBarRecording
        }
    }
}
```

- [ ] **Step 4: Migrate `CaptureSelectionToolbar`** to `CaptureToolType`:

```swift
struct CaptureSelectionToolbar: View {
    let active: CaptureToolType
    let onSelect: (CaptureToolType) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CaptureToolbarPolicy.tools, id: \.self) { tool in
                button(tool)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private func button(_ tool: CaptureToolType) -> some View {
        Button { onSelect(tool) } label: {
            VStack(spacing: 4) {
                Image(systemName: CaptureToolbarPolicy.symbol(for: tool))
                    .font(.system(size: 18))
                Text(L(CaptureToolbarPolicy.labelKey(for: tool)))
                    .font(.caption2)
            }
            .frame(width: 52)
            .foregroundStyle(tool == active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 5: Migrate `SelectionOverlayView`** (in `SelectionOverlayWindow.swift`):

(a) Update the hosting-view type and construction in `init` to pass `active: .region` as a `CaptureToolType`:

```swift
private var toolbarHost: NSHostingView<CaptureSelectionToolbar>?
```
```swift
let host = NSHostingView(rootView: CaptureSelectionToolbar(active: .region) { [weak self] picked in
    self?.toolbarPicked(picked)
})
```

(b) Add two callbacks alongside the existing ones:

```swift
var onScrolling: ((CGRect) -> Void)?
var onRecording: ((CGRect) -> Void)?
```

(c) Rewrite `toolbarPicked` to switch on `CaptureToolType`; scrolling/recording return the current rect in global AppKit coords (guarded against a too-small rect, like region):

```swift
private func toolbarPicked(_ tool: CaptureToolType) {
    switch tool {
    case .region:
        guard !SelectionGeometry.isTooSmall(currentRect) else { return }
        commitRegion(currentRect)
    case .fullscreen:
        onFullscreen?(frozen, CGRect(origin: globalPoint(.zero), size: bounds.size))
    case .window:
        enterWindowSubMode()
    case .scrolling:
        guard !SelectionGeometry.isTooSmall(currentRect) else { return }
        onScrolling?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
    case .recording:
        guard !SelectionGeometry.isTooSmall(currentRect) else { return }
        onRecording?(CGRect(origin: globalPoint(currentRect.origin), size: currentRect.size))
    }
}
```

(d) In `SelectionOverlayWindow.present`, wire the two callbacks next to the existing ones:

```swift
view.onScrolling = { [weak self] rect in self?.finish(.scrolling(rect: rect)) }
view.onRecording = { [weak self] rect in self?.finish(.recording(rect: rect)) }
```

- [ ] **Step 6: Run the toolbar test, then build + full test**

Run: `swift test --filter CaptureToolbarPolicyTests` → PASS (2 tests).
Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(capture): add scrolling and recording to the selection toolbar"
```

---

## Task 5: Changelog + verification

**Files:** Modify `CHANGELOG.md`

- [ ] **Step 1: Add a changelog entry** under `## [Unreleased]` → `### Changed` (the subsection exists from Phase 2):

```markdown
- The capture toolbar now also offers scrolling and recording, acting on the current
  selection — scrolling stitches the selected viewport and recording captures the
  selected region, instead of each starting its own separate selection.
```

- [ ] **Step 2: Build + full test**

Run: `swift build 2>&1 | tail -3` → Build complete!
Run: `swift test 2>&1 | tail -3` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(capture): record scrolling/recording in the selection toolbar"
```

- [ ] **Step 4: Manual verification (user-run, `swift run AnyDoor`)**

1. "截图菜单" → selection + 5-button toolbar (区域/窗口/全屏/滚动/录屏).
2. Adjust the rect, click "滚动" → overlay clears, the selected viewport auto-scrolls and stitches into one tall image.
3. Adjust the rect, click "录屏" → overlay clears, recording starts cropped to the selection (controls window appears); stop → file saved.
4. region/window/fullscreen still behave as in Phase 2; Esc cancels; window sub-mode Esc returns to region.
5. Standalone builtins unchanged: "滚动截图" and "录制屏幕" still run their own flows.

---

## Self-Review notes

- **Spec coverage (Phase 3 rows of §9 / §7.9):** `ScrollCaptureCoordinator.capture(region:)` ✓ Task 1; `RecordingCoordinator.record(rect:)` ✓ Task 2; `SelectionResult.scrolling/recording` + routing ✓ Task 3; `CaptureToolType` + 5-button toolbar emitting scrolling/recording ✓ Task 4. (Spec §7.5 also lists `displayID` on these results; omitted because both coordinators re-derive the display from the global rect themselves — fewer couplings, same behavior.)
- **Type consistency:** `SelectionResult.scrolling(rect:)`/`.recording(rect:)` produced in Task 4 (`onScrolling`/`onRecording` → `finish`), consumed in Task 3 (`handle`). `CaptureToolType` defined in Task 4 Step 1, consumed by `CaptureToolbarPolicy.tools`, `CaptureSelectionToolbar`, and `SelectionOverlayView.toolbarPicked` in the same task. `capture(region:)` / `record(rect:)` defined in Tasks 1-2, called in Task 3.
- **Green-at-every-boundary:** verified in the ordering rationale — coordinators (additive defaults) → results+handle (exhaustive switch closed in one task) → toolbar producer last.
- **Constraints:** no SCK; scrolling keeps its 140 ms clear + `Task.sleep`; recording reuses the existing AVFoundation permission flow; `handle` releases `inFlight` before handing off so the owning coordinator's own guard governs.
- **No regressions:** standalone `.captureScrolling` (`capture()` with `region == nil`) and `.recordScreen` (`toggle()` → `record(region:false)`) paths untouched; `record(region:Bool)` retained for the existing builtin.
</content>
