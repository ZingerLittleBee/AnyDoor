# Translation Window — Liquid Glass Visual Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the translation (`tr`) window's surface system on Liquid Glass (macOS 26+) with a clean material fallback, driven by one shared token layer, without changing layout or behavior.

**Architecture:** A1 "unified glass shell" — the window is one Liquid Glass hero surface; small controls (toolbar buttons, language chips, swap) float as their own interactive glass; the input is a recessed well; result/history cards are flat content tiles (no own material). A new `TranslationTheme` namespace holds spacing/radius/type/tint tokens plus `View` surface helpers layered on the existing `LiquidGlassCompatibility`.

**Tech Stack:** Swift 6.2 (strict concurrency), SwiftUI, AppKit (`NSPanel`), macOS 14+ deployment target with `#available(macOS 26.0, *)` glass gating.

## Global Constraints

- Deployment target macOS 14+; every Liquid Glass call is gated `#available(macOS 26.0, *)` with a non-glass fallback. Copy this idiom verbatim from `Sources/AnyDoor/Views/LiquidGlassCompatibility.swift`.
- No material-on-material stacking on any OS version (the bug being fixed). A surface is glass OR material OR a plain tint — never two stacked.
- Accent color is used ONLY for the Pin active state and primary actions; everything else stays `.secondary` or the surface's own tint.
- Do NOT change layout structure, translation logic, the coordinator, focus/keyboard handling, auto-speak, window sizing, or the `EnterToTranslateEditor` NSTextView bridge.
- All code comments in English. Commit messages follow Conventional Commits (`type(scope): subject`, lowercase subject, imperative). No `Co-Authored-By` / generation watermarks. Do NOT push.
- Verification per task is `swift build` (expected final line `Build complete!`) plus a visual smoke check in `swift run AnyDoor`; the dev machine is Darwin 25 (macOS 26) so the glass branch renders live. Pure visual tokens get no unit tests (per spec).

---

### Task 1: Translation design-token + surface-helper layer

**Files:**
- Create: `Sources/AnyDoor/Views/Translation/TranslationTheme.swift`

**Interfaces:**
- Produces (consumed by all later tasks):
  - `enum TranslationTheme` with static `CGFloat` tokens: `windowPadding` (16), `sectionGap` (12), `tileInsetH` (14), `tileInsetV` (10), `controlGap` (8), `shellRadius` (16), `tileRadius` (12), `controlRadius` (8); static `Color` tokens `wellFill`, `hairline`; static funcs `tileTint(isHovered:isExpanded:) -> Color`, `controlTint(isHovered:) -> Color`.
  - `View.translationShell() -> some View`
  - `View.translationWell() -> some View`
  - `View.translationTile(isHovered:isExpanded:) -> some View`
  - `View.translationControlSurface(shape:isHovered:isActive:idleVisible:) -> some View` (`shape: some Shape`, `isActive: Bool = false`, `idleVisible: Bool = true`)

- [ ] **Step 1: Create the file with tokens and helpers**

Create `Sources/AnyDoor/Views/Translation/TranslationTheme.swift`:

```swift
import SwiftUI

/// Design tokens and adaptive surface helpers for the translation window. Centralizes
/// the spacing, radius, and tint values every translation sub-view used to hardcode,
/// and expresses the "unified glass shell" surface model on top of
/// `LiquidGlassCompatibility`: one glass hero surface, a recessed input well, and
/// flat content tiles for results (no material-on-material stacking on any OS).
enum TranslationTheme {
    // Spacing
    static let windowPadding: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let tileInsetH: CGFloat = 14
    static let tileInsetV: CGFloat = 10
    static let controlGap: CGFloat = 8

    // Radius
    static let shellRadius: CGFloat = 16
    static let tileRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8

    // Tints — plain primary-opacity fills, so they composite cleanly on both the
    // glass shell (macOS 26) and the material shell (fallback) without stacking.
    static let wellFill = Color.primary.opacity(0.04)
    static let hairline = Color.primary.opacity(0.08)

    /// Result/history tile background tint: clear at rest, a faint wash on hover,
    /// slightly stronger while expanded.
    static func tileTint(isHovered: Bool, isExpanded: Bool) -> Color {
        if isExpanded { return Color.primary.opacity(0.07) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }

    /// Small-control fill used on the fallback (pre-macOS-26) path for chips and
    /// toolbar buttons; brightens on hover.
    static func controlTint(isHovered: Bool) -> Color {
        Color.primary.opacity(isHovered ? 0.12 : 0.06)
    }
}

extension View {
    /// The window's hero surface. macOS 26 paints one Liquid Glass sheet; earlier
    /// systems fall back to today's `.regularMaterial`.
    @ViewBuilder
    func translationShell() -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.shellRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }

    /// Recessed input "well": a faint fill plus a hairline stroke, no material/glass,
    /// so it reads as inset on both the glass and the fallback shell.
    func translationWell() -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.tileRadius, style: .continuous)
        return self
            .background(TranslationTheme.wellFill, in: shape)
            .overlay(shape.stroke(TranslationTheme.hairline, lineWidth: 1))
    }

    /// A result/history content tile. No own material — a faint tint marks hover and
    /// the expanded state. This is what removes the old material-on-material stacking.
    func translationTile(isHovered: Bool, isExpanded: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.tileRadius, style: .continuous)
        return self
            .background(TranslationTheme.tileTint(isHovered: isHovered, isExpanded: isExpanded), in: shape)
            .clipShape(shape)
    }

    /// Small interactive control surface for toolbar buttons, language chips, and the
    /// swap button. macOS 26: interactive Liquid Glass, tinted with the accent when
    /// active. Earlier systems: a soft opacity fill (accent fill when active). With
    /// `idleVisible == false` the surface only appears on hover/active, so idle
    /// toolbar glyphs stay flat like the system toolbar treatment.
    @ViewBuilder
    func translationControlSurface(
        shape: some Shape,
        isHovered: Bool,
        isActive: Bool = false,
        idleVisible: Bool = true
    ) -> some View {
        if #available(macOS 26.0, *) {
            if isActive {
                self.glassEffect(.regular.tint(.accentColor).interactive(), in: shape)
            } else if idleVisible || isHovered {
                self.glassEffect(.regular.interactive(), in: shape)
            } else {
                self
            }
        } else {
            if isActive {
                self.background(Color.accentColor, in: shape)
            } else if idleVisible || isHovered {
                self.background(TranslationTheme.controlTint(isHovered: isHovered), in: shape)
            } else {
                self
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: `Build complete!` (the new symbols are unused so far, which is fine — Swift does not warn on unused public-ish helpers).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationTheme.swift
git commit -m "feat(translation): add Liquid Glass design-token and surface layer"
```

---

### Task 2: Apply the shell, glass toolbar, and input well in `TranslationView`

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationView.swift`

**Interfaces:**
- Consumes: `TranslationTheme.*`, `View.translationShell()`, `View.translationWell()`, `View.translationControlSurface(...)`, and `AdaptiveGlassEffectContainer` (from `LiquidGlassCompatibility.swift`).

- [ ] **Step 1: Add a hover state for the pin button**

In `TranslationView`, after the `@State private var showingHistory = false` line (currently `:18`), add:

```swift
    @State private var pinHovered = false
```

- [ ] **Step 2: Swap the root background for the shell**

Replace (currently `:39-40`):

```swift
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
```

with:

```swift
        .translationShell()
        .clipShape(RoundedRectangle(cornerRadius: TranslationTheme.shellRadius, style: .continuous))
```

- [ ] **Step 3: Tokenize the scroll content padding and section gap**

Replace (currently `:31` and `:36`) the `VStack(spacing: 12)` / `.padding(14)`:

```swift
                VStack(spacing: 12) {
                    inputCard
                    LanguageBar(coordinator: coordinator) { runTranslation() }
                    resultCards
                }
                .padding(14)
```

with:

```swift
                VStack(spacing: TranslationTheme.sectionGap) {
                    inputCard
                    LanguageBar(coordinator: coordinator) { runTranslation() }
                    resultCards
                }
                .padding(TranslationTheme.windowPadding)
```

- [ ] **Step 4: Wrap the toolbar in a glass container and use the toolbar button view**

Replace the whole `toolbar` computed property (currently `:53-78`):

```swift
    private var toolbar: some View {
        HStack(spacing: 10) {
            Spacer()
            pinButton
            toolbarButton(systemImage: "clock.arrow.circlepath", help: L(.translationHistory)) {
                showingHistory.toggle()
            }
            .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                TranslationHistoryView(
                    store: TranslationHistoryStore.shared,
                    coordinator: coordinator
                ) {
                    showingHistory = false
                }
            }
            toolbarButton(systemImage: "camera.viewfinder", help: L(.translationScreenshot)) {
                controller.close()
                Task { await PanelStore.shared.run(.screenshotTranslate) }
            }
            toolbarButton(systemImage: "gearshape", help: L(.translationSettings)) {
                SettingsOpener.shared.tryOpen(tab: .translation)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
```

with:

```swift
    private var toolbar: some View {
        AdaptiveGlassEffectContainer(spacing: TranslationTheme.controlGap) {
            HStack(spacing: TranslationTheme.controlGap) {
                Spacer()
                pinButton
                TranslationToolbarButton(systemImage: "clock.arrow.circlepath", help: L(.translationHistory)) {
                    showingHistory.toggle()
                }
                .popover(isPresented: $showingHistory, arrowEdge: .bottom) {
                    TranslationHistoryView(
                        store: TranslationHistoryStore.shared,
                        coordinator: coordinator
                    ) {
                        showingHistory = false
                    }
                }
                TranslationToolbarButton(systemImage: "camera.viewfinder", help: L(.translationScreenshot)) {
                    controller.close()
                    Task { await PanelStore.shared.run(.screenshotTranslate) }
                }
                TranslationToolbarButton(systemImage: "gearshape", help: L(.translationSettings)) {
                    SettingsOpener.shared.tryOpen(tab: .translation)
                }
            }
        }
        .padding(.horizontal, TranslationTheme.windowPadding)
        .padding(.vertical, 8)
    }
```

- [ ] **Step 5: Rewrite the pin button to use the control surface**

Replace the `pinButton` computed property (currently `:83-106`):

```swift
    private var pinButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isPinned.toggle() }
            controller.setPinned(isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: isPinned ? .semibold : .regular))
                .foregroundStyle(isPinned ? Color.white : Color.secondary)
                .frame(width: 24, height: 24)
                .background {
                    if isPinned {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        // ⌘P toggles pin; the panel is key while open, so its performKeyEquivalent
        // fires this even while the input has focus. Tooltip surfaces the shortcut.
        .keyboardShortcut("p", modifiers: .command)
        .accessibilityLabel(L(isPinned ? .translationUnpin : .translationPin))
        .hoverTooltip(L(isPinned ? .translationUnpin : .translationPin) + " ⌘P")
    }
```

with:

```swift
    private var pinButton: some View {
        let shape = RoundedRectangle(cornerRadius: TranslationTheme.controlRadius, style: .continuous)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { isPinned.toggle() }
            controller.setPinned(isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: isPinned ? .semibold : .regular))
                .foregroundStyle(isPinned ? Color.white : Color.secondary)
                .frame(width: 24, height: 24)
                .translationControlSurface(shape: shape, isHovered: pinHovered, isActive: isPinned, idleVisible: false)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { pinHovered = $0 }
        // ⌘P toggles pin; the panel is key while open, so its performKeyEquivalent
        // fires this even while the input has focus. Tooltip surfaces the shortcut.
        .keyboardShortcut("p", modifiers: .command)
        .accessibilityLabel(L(isPinned ? .translationUnpin : .translationPin))
        .hoverTooltip(L(isPinned ? .translationUnpin : .translationPin) + " ⌘P")
    }
```

- [ ] **Step 6: Replace the `toolbarButton` helper with a self-hovering view**

Replace the `toolbarButton(systemImage:help:action:)` function (currently `:108-119`):

```swift
    private func toolbarButton(systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
        .accessibilityLabel(help)
        .hoverTooltip(help)
    }
```

with a private struct (a function can't hold the per-button hover `@State`):

```swift
    /// A toolbar glyph button whose small control surface appears only on hover
    /// (macOS 26: interactive glass; earlier: a soft tint), so idle toolbar glyphs
    /// stay flat like the system toolbar.
    private struct TranslationToolbarButton: View {
        let systemImage: String
        let help: String
        let action: () -> Void
        @State private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: TranslationTheme.controlRadius, style: .continuous)
            return Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .translationControlSurface(shape: shape, isHovered: hovered, idleVisible: false)
                    .contentShape(shape)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(help)
            .hoverTooltip(help)
        }
    }
```

- [ ] **Step 7: Swap the input card material for the well**

Replace (currently `:166-167`):

```swift
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
```

with:

```swift
        .padding(10)
        .translationWell()
```

- [ ] **Step 8: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 9: Visual smoke check**

Run: `swift run AnyDoor`, summon the translation panel (its hotkey). Confirm: the window is one cohesive glass/material surface; toolbar glyphs are flat at rest and gain a glass/tint chip on hover; the Pin button shows the accent state when toggled; the input area reads as an inset well, not a raised card.

- [ ] **Step 10: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationView.swift
git commit -m "refactor(translation): adopt glass shell, toolbar, and input well"
```

---

### Task 3: Glass language chips and swap button in `LanguageBar`

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/LanguageBar.swift`

**Interfaces:**
- Consumes: `TranslationTheme.controlGap`, `View.translationControlSurface(...)`, `AdaptiveGlassEffectContainer`.

- [ ] **Step 1: Wrap the bar in a glass container**

Replace the `body` (currently `:25-34`):

```swift
    var body: some View {
        HStack(spacing: 8) {
            sourcePicker
                .frame(maxWidth: .infinity, alignment: .center)
            swapButton
            targetPicker
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(.callout)
    }
```

with:

```swift
    var body: some View {
        AdaptiveGlassEffectContainer(spacing: TranslationTheme.controlGap) {
            HStack(spacing: TranslationTheme.controlGap) {
                sourcePicker
                    .frame(maxWidth: .infinity, alignment: .center)
                swapButton
                targetPicker
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .font(.callout)
    }
```

- [ ] **Step 2: Give the swap button a glass circle**

Replace (currently `:87`):

```swift
                .background(Circle().fill(fill(swapHovered)))
```

with:

```swift
                .translationControlSurface(shape: Circle(), isHovered: swapHovered)
```

- [ ] **Step 3: Give the chips a glass capsule**

Replace (currently `:116`) inside the `capsule(_:hovered:)` helper:

```swift
        .background(Capsule().fill(fill(hovered)))
```

with:

```swift
        .translationControlSurface(shape: Capsule(), isHovered: hovered)
```

- [ ] **Step 4: Delete the now-unused `fill(_:)` helper**

Remove (currently `:120-122`):

```swift
    private func fill(_ hovered: Bool) -> Color {
        Color.primary.opacity(hovered ? 0.12 : 0.06)
    }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Visual smoke check**

In the running app, confirm both language chips and the swap button render as small glass controls; the swap control sits centered between the two chips and the glass merges nicely when they are close (macOS 26).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/LanguageBar.swift
git commit -m "refactor(translation): render language chips and swap as glass controls"
```

---

### Task 4: Flatten `TranslationServiceCard` into a content tile

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift`

**Interfaces:**
- Consumes: `TranslationTheme.tileInsetH`, `TranslationTheme.tileInsetV`, `View.translationTile(isHovered:isExpanded:)`.

- [ ] **Step 1: Add a hover state**

After `@State private var collapsed: Bool` (currently `:18`), add:

```swift
    @State private var hovered = false
```

- [ ] **Step 2: Replace the card material with the tile surface**

Replace (currently `:46-47`):

```swift
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
```

with:

```swift
        .translationTile(isHovered: hovered, isExpanded: !collapsed)
        .onHover { hovered = $0 }
```

- [ ] **Step 3: Tokenize the body padding**

Replace (currently `:40-41`):

```swift
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
```

with:

```swift
                        .padding(.horizontal, TranslationTheme.tileInsetH)
                        .padding(.vertical, TranslationTheme.tileInsetV)
```

- [ ] **Step 4: Tokenize the header horizontal padding and standardize the timing**

Replace (currently `:90-91`):

```swift
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
```

with:

```swift
        .padding(.horizontal, TranslationTheme.tileInsetH)
        .padding(.vertical, 8)
```

Then replace (currently `:98`):

```swift
        withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
```

with:

```swift
        withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Visual smoke check**

Run a translation. Confirm result cards no longer carry a raised `.thinMaterial` rectangle — they read as flat tiles on the shell, gaining a faint wash on hover and while expanded, separated by spacing. No light-mode brightening/flattening.

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationServiceCard.swift
git commit -m "refactor(translation): flatten service result card into a content tile"
```

---

### Task 5: Flatten `AppleTranslationCard` into a content tile

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/AppleTranslationCard.swift`

**Interfaces:**
- Consumes: `TranslationTheme.tileInsetH`, `TranslationTheme.tileInsetV`, `View.translationTile(isHovered:isExpanded:)`.

- [ ] **Step 1: Add a hover state**

In `AppleTranslationCardBody`, after `@State private var collapsed = false` (currently `:67`), add:

```swift
    @State private var hovered = false
```

- [ ] **Step 2: Replace the card material with the tile surface**

Replace (currently `:106-107`) inside the `card` property:

```swift
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
```

with:

```swift
        .translationTile(isHovered: hovered, isExpanded: !collapsed)
        .onHover { hovered = $0 }
```

- [ ] **Step 3: Tokenize the body padding**

Replace (currently `:100-101`):

```swift
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
```

with:

```swift
                        .padding(.horizontal, TranslationTheme.tileInsetH)
                        .padding(.vertical, TranslationTheme.tileInsetV)
```

- [ ] **Step 4: Tokenize the header horizontal padding and standardize the timing**

Replace (currently `:160-161`):

```swift
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
```

with:

```swift
        .padding(.horizontal, TranslationTheme.tileInsetH)
        .padding(.vertical, 8)
```

Then replace (currently `:167`):

```swift
        withAnimation(.easeInOut(duration: 0.22)) { collapsed.toggle() }
```

with:

```swift
        withAnimation(.easeInOut(duration: 0.2)) { collapsed.toggle() }
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 6: Visual smoke check**

On macOS 15+, run a translation that produces an Apple on-device result. Confirm the Apple card matches the other result tiles exactly (flat tile, same insets, same hover/expanded wash).

- [ ] **Step 7: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/AppleTranslationCard.swift
git commit -m "refactor(translation): flatten Apple result card into a content tile"
```

---

### Task 6: Flatten history cards in `TranslationHistoryView`

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift`

**Interfaces:**
- Consumes: `View.translationTile(isHovered:isExpanded:)`.

**Note:** The spec listed "popover background → adaptivePanelSurface", but the SwiftUI `.popover` already supplies its own system material chrome; layering `adaptivePanelSurface` on top would re-introduce exactly the material-on-material stacking this redesign removes. So the popover chrome is intentionally left to the system, and this task only flattens the inner history cards (the actual stacked `.thinMaterial`). This is a deliberate, spec-aligned refinement.

- [ ] **Step 1: Replace the history card material with the tile surface**

Replace (currently `:142-143`) at the end of the `card(_:)` function:

```swift
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
```

with:

```swift
        .padding(8)
        .translationTile(isHovered: false, isExpanded: expandedID == group.id)
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Visual smoke check**

Open the history popover (toolbar clock button). Confirm history cards read as flat tiles (no raised material rectangle); the expanded card gains a faint wash. Filter buttons and star/delete controls are unchanged and still legible.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationHistoryView.swift
git commit -m "refactor(translation): flatten history cards into content tiles"
```

---

### Task 7: Align the service editor dialog surface

**Files:**
- Modify: `Sources/AnyDoor/Views/Translation/TranslationServiceEditorOverlay.swift`

**Interfaces:**
- Consumes: `View.adaptivePanelSurface(cornerRadius:)` (from `LiquidGlassCompatibility.swift`).

**Note:** Light pass only — the dialog card surface is aligned to the adaptive glass/material panel. The `TranslationServiceConfigSheet` Form internals (a separate file) are out of scope and untouched.

- [ ] **Step 1: Use the adaptive panel surface for the dialog card**

Replace (currently `:135-136`) inside `TranslationServiceEditorScrim.body`:

```swift
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
```

with:

```swift
                .adaptivePanelSurface(cornerRadius: 16)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Visual smoke check**

Open Settings → Translation → add/edit a service. Confirm the centered editor dialog renders as a Liquid Glass panel on macOS 26 (thick material on the fallback), still over the dimmed scrim, with its shadow intact and text fields fully usable.

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/Translation/TranslationServiceEditorOverlay.swift
git commit -m "style(translation): align service editor dialog to the adaptive glass panel"
```

---

## Self-Review

**Spec coverage:**
- Token layer (`TranslationTheme.swift`) → Task 1. ✓ (spacing/radius/type intent + accent rule documented; type tokens are applied where each view sets fonts, but the existing `.subheadline.semibold` / `.body` / `.caption` already match the spec's type scale, so no font edits are required — the rule is encoded as the accent/tint policy in Task 1's doc comments).
- Glass shell + glass toolbar + input well (`TranslationView`) → Task 2. ✓
- Language chips/swap as glass + container → Task 3. ✓
- Result tiles, no material, hairline/spacing separation + standardized timing (`TranslationServiceCard`, `AppleTranslationCard`) → Tasks 4 & 5. ✓
- History cards → tile (`TranslationHistoryView`) → Task 6. ✓ (popover-background sub-item intentionally dropped with rationale, to honor the no-stacking constraint).
- Editor overlay light pass → Task 7. ✓
- Fallback removes material stacking on all OS versions → encoded in `translationTile` / `translationWell` (identical on both paths) and the fallback branches of `translationShell` / `translationControlSurface`. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete before/after code. ✓

**Type consistency:** `translationControlSurface(shape:isHovered:isActive:idleVisible:)`, `translationTile(isHovered:isExpanded:)`, `translationWell()`, `translationShell()` are defined in Task 1 and consumed with matching labels in Tasks 2–6; `adaptivePanelSurface(cornerRadius:)` and `AdaptiveGlassEffectContainer` come from the existing `LiquidGlassCompatibility.swift`. ✓

## Notes for the implementer

- Line numbers are as of plan authoring; if an earlier task shifts lines in a file, locate the quoted snippet by its text, not the number. Each task touches a distinct file, so cross-task drift is minimal.
- The accent rule is a policy, not a single call site: when in doubt, a control is `.secondary` unless it is the Pin active state or a primary action.
- If a glass control reads as too heavy at idle, the lever is `idleVisible` on `translationControlSurface` (toolbar uses `false`; chips use the default `true`).
