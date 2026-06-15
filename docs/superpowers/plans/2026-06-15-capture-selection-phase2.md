# Capture Selection — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the "截图菜单" (`.captureModeBar`) entry — and the shared region entry — open the pre-shown selection directly with an attached SwiftUI toolbar below it that switches capture type (region / window / fullscreen), executing on the current selection; remove the standalone floating `CaptureModeBarWindow`.

**Architecture:** Approach A from the design spec (`docs/superpowers/specs/2026-06-15-capture-selection-toolbar-design.md` §5). The toolbar is an `NSHostingView` subview of the per-screen `SelectionOverlayView`, positioned below the selection via the existing pure `OverlayPlacement.frame`. The background view keeps owning drawing + gestures. The `.region` overlay becomes the unified entry; its `mode` is now mutable so the toolbar's "window" button switches the same overlay into a window-pick sub-mode. region/window/fullscreen all flow back through one coordinator handler.

**Tech Stack:** Swift 6.2 strict concurrency, AppKit `NSPanel`/`NSView`, SwiftUI `NSHostingView`, `LegacyScreenCapture` (synchronous CoreGraphics — **never** ScreenCaptureKit, per the executor-corruption constraint), XCTest pure-geometry tests.

**Scope decisions (confirmed with user):**
- Toolbar shows **region / window / fullscreen** only. Scrolling/recording stay on their own builtins this phase (Phase 3 wires the rect through them).
- Both `.screenshot` ("截图到剪贴板") and `.captureModeBar` ("截图菜单") open the same unified overlay (now with toolbar). The two builtins remain; they share one overlay.
- `CaptureToolType` (spec §7.1) is **not** introduced this phase: the three Phase-2 types are exactly `CaptureMode` cases, so the toolbar emits `CaptureMode`. Phase 3 introduces `CaptureToolType` when scrolling/recording (non-modes) join.

**Constraints to preserve:**
- No `await` of any cross-isolation async on a `@MainActor` frame in the capture flow (executor-corruption bug). All new code is callback / synchronous.
- The frozen still passed into the overlay is a clean full-display `LegacyScreenCapture.display(id)` grab; the dim is drawn on top. So "fullscreen" can return the frozen still directly (no re-grab).
- UI strings stay Chinese via `L(.key)`; code/comments/commit English.

---

## File Structure

- Modify `Sources/AnyDoor/Services/Capture/CaptureTypes.swift` — add `SelectionResult.fullscreen(image:)`.
- Create `Sources/AnyDoor/Services/Capture/CaptureToolbarPolicy.swift` — pure list of Phase-2 toolbar modes (single source of truth + test anchor).
- Create `Sources/AnyDoor/Views/Capture/CaptureSelectionToolbar.swift` — SwiftUI pill, 3 buttons, emits `CaptureMode`.
- Modify `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift` — wire `onFullscreen`; host the toolbar subview; mutable `mode` + window sub-mode; toolbar positioning/visibility.
- Modify `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift` — `handle(_:delay:)` routes region/window/fullscreen; remove `presentModeBar`.
- Modify `Sources/AnyDoor/Services/Providers/CaptureProviders.swift` — `CaptureModeBarProvider` → unified region entry.
- Delete `Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift`.
- Delete `Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift`.
- Delete `Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift`.
- Create `Tests/AnyDoorTests/CaptureToolbarPolicyTests.swift`.
- Modify `CHANGELOG.md`.

> AppKit view code (`SelectionOverlayWindow`) cannot be unit-tested here (no headless AppKit + the SCK/executor constraint), exactly as in Phase 1. Those tasks are build-verified; the only new pure test is `CaptureToolbarPolicy`. Interactive verification is the user's (checklist in Task 8).

---

## Task 1: `CaptureToolbarPolicy` (pure) — toolbar mode list

**Files:**
- Create: `Sources/AnyDoor/Services/Capture/CaptureToolbarPolicy.swift`
- Test: `Tests/AnyDoorTests/CaptureToolbarPolicyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AnyDoor

final class CaptureToolbarPolicyTests: XCTestCase {
    func testPhase2ModesAreRegionWindowFullscreenInOrder() {
        XCTAssertEqual(CaptureToolbarPolicy.modes, [.region, .window, .fullscreen])
    }

    func testEveryModeHasASymbolAndLabelKey() {
        for mode in CaptureToolbarPolicy.modes {
            XCTAssertFalse(CaptureToolbarPolicy.symbol(for: mode).isEmpty)
            // label key resolves to a non-empty localized string
            XCTAssertFalse(L(CaptureToolbarPolicy.labelKey(for: mode)).isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CaptureToolbarPolicyTests`
Expected: FAIL (no such type `CaptureToolbarPolicy`).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Pure description of the attached capture toolbar's buttons. Phase 2 shows
/// region / window / fullscreen (each is exactly a `CaptureMode`). Scrolling and
/// recording join in Phase 3 via a richer tool-type enum.
enum CaptureToolbarPolicy {
    /// Buttons rendered, left to right.
    static let modes: [CaptureMode] = [.region, .window, .fullscreen]

    /// SF Symbol for each toolbar button.
    static func symbol(for mode: CaptureMode) -> String {
        switch mode {
        case .region:     return "rectangle.dashed"
        case .window:     return "macwindow"
        case .fullscreen: return "rectangle.inset.filled"
        }
    }

    /// Localized label key (reuses the existing mode-bar strings).
    static func labelKey(for mode: CaptureMode) -> L10n.Key {
        switch mode {
        case .region:     return .captureModeBarRegion
        case .window:     return .captureModeBarWindow
        case .fullscreen: return .captureModeBarFullscreen
        }
    }
}
```

> `L(_:)` is declared `func L(_ key: L10n.Key, ...)` (see `Utilities/L10n.swift:420`); the label cases (`captureModeBarRegion` etc.) live under `L10n.Key`. Hence `labelKey(for:) -> L10n.Key`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter CaptureToolbarPolicyTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureToolbarPolicy.swift Tests/AnyDoorTests/CaptureToolbarPolicyTests.swift
git commit -m "feat(capture): add CaptureToolbarPolicy for the attached toolbar modes"
```

---

## Task 2: `SelectionResult.fullscreen` + coordinator `handle(_:delay:)` routing

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/CaptureTypes.swift:38-47`
- Modify: `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift:69-130`

- [ ] **Step 1: Add the `.fullscreen` result case**

In `CaptureTypes.swift`, extend `SelectionResult`:

```swift
enum SelectionResult: Sendable {
    case region(image: CGImage, rect: CGRect)
    case window(id: CGWindowID, frame: CGRect)
    /// Whole-display capture chosen from the toolbar. The overlay returns its
    /// clean frozen still directly (no re-grab); `frame` is the display's global
    /// AppKit frame (for symmetry — the output overlay uses no anchor here).
    case fullscreen(image: CGImage, frame: CGRect)
    case cancelled
}
```

- [ ] **Step 2: Refactor the coordinator to route all three results through one handler**

In `CaptureCoordinator.swift`, replace the body of `captureRegion(delay:)`'s completion and `captureWindow(delay:)`'s completion with a shared `handle`. Add:

```swift
/// Routes a selection overlay result through the output policy. Shared by the
/// unified region overlay (which can return region/window/fullscreen via the
/// toolbar) and the standalone window overlay.
private func handle(_ result: SelectionResult, delay: Int) {
    switch result {
    case let .region(cgImage, rect):
        settings.setLastRegionRect(rect)
        afterCountdown(delay) { [weak self] in
            self?.present(image: cgImage, anchor: rect)
            self?.finish()
        }
    case let .window(id, frame):
        afterCountdown(delay) { [weak self] in
            guard let self else { return }
            guard let cg = LegacyScreenCapture.window(id) else {
                ToastPresenter.shared.show(.failure(L(.captureToastFailed)))
                self.finish(); return
            }
            self.present(image: cg, anchor: frame)
            self.finish()
        }
    case let .fullscreen(cgImage, _):
        afterCountdown(delay) { [weak self] in
            self?.present(image: cgImage, anchor: nil)
            self?.finish()
        }
    case .cancelled:
        finish()
    }
}
```

Then make `captureRegion` use it:

```swift
private func captureRegion(delay: Int) {
    let (targets, frozen) = Self.resolveAllDisplays()
    guard !targets.isEmpty else { finish(); return }
    let initialRect = Self.initialSelectionRect(targets: targets, settings: settings)
    selectionOverlay.present(targets: targets, mode: .region, frozen: frozen, initialRect: initialRect) { [weak self] result in
        self?.handle(result, delay: delay)
    }
}
```

And `captureWindow`:

```swift
private func captureWindow(delay: Int) {
    let (targets, frozen) = Self.resolveAllDisplays()
    guard !targets.isEmpty else { finish(); return }
    selectionOverlay.present(targets: targets, mode: .window, frozen: frozen) { [weak self] result in
        self?.handle(result, delay: delay)
    }
}
```

> `captureFullscreen(delay:)` (the standalone `.captureFullscreen` builtin) is unchanged — it grabs directly without the overlay.

- [ ] **Step 3: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete! (a non-exhaustive-switch error elsewhere on `SelectionResult` would surface here — Task 4 adds the producer; for now the only consumers are in this file and they are exhaustive.)

- [ ] **Step 4: Full test suite (no regressions)**

Run: `swift test 2>&1 | tail -6`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Capture/CaptureTypes.swift Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift
git commit -m "refactor(capture): route region/window/fullscreen results through one handler"
```

---

## Task 3: `CaptureSelectionToolbar` SwiftUI view

**Files:**
- Create: `Sources/AnyDoor/Views/Capture/CaptureSelectionToolbar.swift`

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// Attached capture-type toolbar shown directly below the selection rectangle.
/// A horizontal material pill of type buttons (region / window / fullscreen).
/// Emits the chosen `CaptureMode`; the hosting overlay executes it on the
/// current selection. Sized to fit so the host can place it via `OverlayPlacement`.
struct CaptureSelectionToolbar: View {
    /// Highlighted button (the current/active type).
    let active: CaptureMode
    let onSelect: (CaptureMode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CaptureToolbarPolicy.modes, id: \.self) { mode in
                button(mode)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }

    private func button(_ mode: CaptureMode) -> some View {
        Button { onSelect(mode) } label: {
            VStack(spacing: 4) {
                Image(systemName: CaptureToolbarPolicy.symbol(for: mode))
                    .font(.system(size: 18))
                Text(L(CaptureToolbarPolicy.labelKey(for: mode)))
                    .font(.caption2)
            }
            .frame(width: 52)
            .foregroundStyle(mode == active ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
```

> `CaptureMode` is `CaseIterable`/`Hashable` via its `String` raw value, so `id: \.self` is valid. If the compiler rejects `\.self`, add `: Hashable` is already implied by `String` raw value — no change needed.

- [ ] **Step 2: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/CaptureSelectionToolbar.swift
git commit -m "feat(capture): add attached CaptureSelectionToolbar view"
```

---

## Task 4: Host the toolbar in `SelectionOverlayView` + fullscreen dispatch

**Files:**
- Modify: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift`

Add the toolbar as a subview of `SelectionOverlayView`, positioned below `currentRect`, visible only while `mode == .region && !currentRect.isEmpty`. Wire the toolbar's `.region`/`.fullscreen` actions (window handled in Task 5).

- [ ] **Step 1: Add `import SwiftUI`** at the top of the file (keep `import AppKit`, `import CoreGraphics`).

- [ ] **Step 2: Add `onFullscreen` callback and wire it in `present`**

In `SelectionOverlayView`, add alongside the other callbacks:

```swift
var onFullscreen: ((CGImage, CGRect) -> Void)?
```

In `SelectionOverlayWindow.present`, after the existing `view.onWindow = ...` line, add:

```swift
view.onFullscreen = { [weak self] image, frame in self?.finish(.fullscreen(image: image, frame: frame)) }
```

- [ ] **Step 3: Add the hosting view + placement**

In `SelectionOverlayView`, add stored properties:

```swift
/// The attached toolbar (region/window/fullscreen), hosted as a subview and
/// repositioned below the selection on every change. Only built for an overlay
/// whose initial mode is `.region` (the unified entry); the standalone window
/// overlay has no toolbar.
private var toolbarHost: NSHostingView<CaptureSelectionToolbar>?
private static let toolbarGap: CGFloat = 10
```

At the end of `init` (after `NSCursor.crosshair.set()`), build the toolbar only for region-initial overlays:

```swift
if mode == .region {
    let host = NSHostingView(rootView: CaptureSelectionToolbar(active: .region) { [weak self] picked in
        self?.toolbarPicked(picked)
    })
    host.translatesAutoresizingMaskIntoConstraints = true   // we set .frame manually
    addSubview(host)
    toolbarHost = host
}
```

Add the placement + visibility updater and call it whenever the rect or mode changes:

```swift
/// Position the toolbar below the current selection (flipping above near the
/// screen bottom) and hide it unless a region selection is being shown.
private func layoutToolbar() {
    guard let host = toolbarHost else { return }
    let show = (mode == .region) && !currentRect.isEmpty
    host.isHidden = !show
    guard show else { return }
    let size = host.fittingSize
    host.frame = OverlayPlacement.frame(
        forRegion: currentRect, overlaySize: size, onScreen: bounds, gap: Self.toolbarGap
    )
}

private func toolbarPicked(_ mode: CaptureMode) {
    switch mode {
    case .region:
        guard !SelectionGeometry.isTooSmall(currentRect) else { return }
        commitRegion(currentRect)
    case .fullscreen:
        // The frozen still is the clean full display; return it directly.
        onFullscreen?(frozen, CGRect(origin: globalPoint(.zero), size: bounds.size))
    case .window:
        enterWindowSubMode()   // implemented in Task 5
    }
}
```

> Until Task 5 lands, stub `enterWindowSubMode()` as an empty method so this compiles, then flesh it out in Task 5.

- [ ] **Step 4: Call `layoutToolbar()` after every rect/mode change**

Add a `layoutToolbar()` call at the end of: `mouseDragged` (after `needsDisplay = true`), `mouseUp` (region branch), `handleArrowKey` (after `needsDisplay = true`), and once at the end of `init` (after building the host) and in `mouseDown` (after `needsDisplay = true`). Also override `layout()` to keep it positioned on resize:

```swift
override func layout() {
    super.layout()
    layoutToolbar()
}
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 6: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): attach toolbar below the selection with region/fullscreen actions"
```

---

## Task 5: Window sub-mode (toolbar "window" switches the live overlay)

**Files:**
- Modify: `Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift`

Make `mode` mutable so the toolbar's window button switches the same overlay into window-pick; Esc returns to region (for the unified entry) or cancels (for the standalone window entry).

- [ ] **Step 1: Make `mode` mutable, record the initial mode, lazy windows**

Change:

```swift
private let mode: CaptureMode
private let windows: [CapturableWindow]
```
to:
```swift
private var mode: CaptureMode
private let initialMode: CaptureMode
private var windows: [CapturableWindow]
```

In `init`, set both and keep the existing window-mode eager enumeration:

```swift
self.mode = mode
self.initialMode = mode
self.windows = mode == .window ? WindowEnumerator.onScreenWindows() : []
```

- [ ] **Step 2: Implement enter/exit sub-mode**

```swift
/// Toolbar "window" → switch the live overlay into window-pick: hide the rect +
/// toolbar, enumerate windows, highlight on hover, commit on click.
private func enterWindowSubMode() {
    windows = WindowEnumerator.onScreenWindows()
    mode = .window
    hoveredWindow = nil
    layoutToolbar()     // hides the toolbar (mode != .region)
    NSCursor.crosshair.set()
    needsDisplay = true
}

/// Esc from a toolbar-entered window sub-mode returns to region selection.
private func exitToRegionMode() {
    mode = .region
    hoveredWindow = nil
    layoutToolbar()     // re-shows the toolbar
    needsDisplay = true
}
```

- [ ] **Step 3: Branch Esc on initial vs current mode**

In `keyDown`, replace the `case 53` Esc handling:

```swift
case 53: // Esc
    if mode == .window && initialMode == .region {
        exitToRegionMode()   // return to region instead of cancelling
    } else {
        onCancel?()
    }
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/Capture/SelectionOverlayWindow.swift
git commit -m "feat(capture): switch the live overlay into window sub-mode from the toolbar"
```

---

## Task 6: Route `CaptureModeBarProvider` to the unified overlay; remove `presentModeBar`

**Files:**
- Modify: `Sources/AnyDoor/Services/Capture/CaptureCoordinator.swift:47-58`
- Modify: `Sources/AnyDoor/Services/Providers/CaptureProviders.swift:56-65`
- Delete: `Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift`

- [ ] **Step 1: Delete `presentModeBar()`** from `CaptureCoordinator` (the whole method, lines 47-58).

- [ ] **Step 2: Repoint the provider**

In `CaptureProviders.swift`, change `CaptureModeBarProvider.run()`:

```swift
/// Open the unified capture overlay (pre-shown selection + attached type toolbar).
actor CaptureModeBarProvider: ActionProvider {
    let itemKey: BuiltinItem = .captureModeBar
    var permission: PermissionStatus { .notRequired }
    func run() async {
        await MainActor.run { CaptureCoordinator.shared.capture(CaptureRequest(mode: .region)) }
    }
}
```

- [ ] **Step 3: Delete `CaptureModeBarWindow.swift`**

```bash
git rm Sources/AnyDoor/Views/Capture/CaptureModeBarWindow.swift
```

- [ ] **Step 4: Build (catches any remaining references)**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete! If a reference to `CaptureModeBarWindow` remains, fix it (there should be none outside the deleted method).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(capture): open the unified overlay from the capture-menu entry"
```

---

## Task 7: Remove `CaptureModeBarPolicy` + its tests; prune orphaned strings

**Files:**
- Delete: `Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift`
- Delete: `Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift`

- [ ] **Step 1: Confirm `CaptureModeBarPolicy` has no remaining references**

Run: `grep -rn "CaptureModeBarPolicy" Sources Tests`
Expected: no matches (the only user was `CaptureModeBarWindow`, deleted in Task 6).

- [ ] **Step 2: Delete the files**

```bash
git rm Sources/AnyDoor/Services/Capture/CaptureModeBarPolicy.swift Tests/AnyDoorTests/CaptureModeBarPolicyTests.swift
```

- [ ] **Step 3: Check for now-orphaned L10n keys**

Run: `grep -rn "captureModeBarTimer" Sources`
The toolbar uses region/window/fullscreen; `capture.modeBar.timer` is now unused, while `capture.modeBar.recording` / `capture.modeBar.scrolling` are reserved for Phase 3. Leave recording/scrolling. Removing the orphaned `captureModeBarTimer` key is optional — if removed, delete both the `L10n` enum case in `Utilities/L10n.swift` and the `capture.modeBar.timer` entry in `Resources/Localizable.xcstrings`. Default: **leave it** (harmless, avoids xcstrings churn) and note it in the commit body.

- [ ] **Step 4: Build + full test suite**

Run: `swift build 2>&1 | tail -5` → Build complete!
Run: `swift test 2>&1 | tail -6` → 0 failures (the `CaptureModeBarPolicyTests` count drops; `CaptureToolbarPolicyTests` is present).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(capture): drop CaptureModeBarPolicy and its tests"
```

---

## Task 8: Changelog + manual verification checklist

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Add a changelog entry** under `## [Unreleased]` → `### Changed` (create the `### Changed` subsection if absent, after `### Added`):

```markdown
### Changed

- The capture-menu entry now opens the pre-shown selection directly with an attached
  toolbar (region / window / fullscreen) instead of a separate type-picker bar; the
  standalone floating mode bar was removed.
```

- [ ] **Step 2: Build + full test**

Run: `swift build 2>&1 | tail -5` → Build complete!
Run: `swift test 2>&1 | tail -6` → 0 failures.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(capture): record the unified capture-menu toolbar in the changelog"
```

- [ ] **Step 4: Manual verification (user-run, `swift run AnyDoor`)**

1. Click "截图菜单" → the selection box appears immediately (no type-picker first), with the toolbar below it.
2. Toolbar follows the selection on move/resize; flips above near the screen bottom.
3. Click "区域" (or press Enter) → region screenshot of the current rect.
4. Click "窗口" → rect/toolbar hide, hover highlights a window, click captures it; Esc returns to the region selection (not cancel).
5. Click "全屏" → whole-display screenshot.
6. Esc from region selection cancels. Multi-display: toolbar appears on whichever screen holds the active rect.
7. "截图到剪贴板" opens the same overlay+toolbar (shared entry).

---

## Self-Review notes

- **Spec coverage:** Phase-2 rows of spec §9 — attached toolbar (§7.4 ✓ Task 3), below the selection following it (§5/§7.3 ✓ Task 4), region/window/fullscreen (✓ Tasks 2/4/5), Enter/Esc (✓ existing + Task 5), route the unified entry in (✓ Task 6), remove `CaptureModeBarWindow` (✓ Tasks 6/7). Scrolling/recording toolbar buttons and `CaptureToolType` intentionally deferred to Phase 3 (user-confirmed).
- **Type consistency:** `SelectionResult.fullscreen(image:frame:)` produced in Task 4 (`onFullscreen`), consumed in Task 2 (`handle`). `CaptureToolbarPolicy.modes: [CaptureMode]` consumed by the toolbar (Task 3) and conceptually by the view dispatch (Task 4). `mode` mutated only within `SelectionOverlayView`.
- **Risk (spec §11):** SwiftUI buttons inside a non-activating `.screenSaver` panel must receive clicks. The panel is `canBecomeKey` and made key; the hosting view is a subview on top so AppKit hit-tests route clicks to it. This is the primary thing the manual checklist validates (steps 1/3/4/5). If clicks don't register, the fallback is to host the toolbar in a sibling child `NSPanel` (Approach B) — not expected to be needed.
</content>
</invoke>
