# Translation Window — Liquid Glass Visual Redesign

**Date:** 2026-06-25
**Status:** Approved (design)
**Scope:** Visual refactor of the translation (`tr`) floating window. Structure and
behavior unchanged; this rebuilds the *surface system* on top of Liquid Glass.

## Problem

The translation window currently stacks materials: the root paints
`.regularMaterial` (`TranslationView.swift:39`) and every inner element paints a
second material on top — the input card and result cards each use `.thinMaterial`
in a `RoundedRectangle(12)` (`TranslationView.swift:167`, `TranslationServiceCard.swift`,
`AppleTranslationCard.swift`), and the history popover cards use `.thinMaterial`
in a `RoundedRectangle(10)`. This is exactly the material-on-material anti-pattern
the codebase already warns about in `LiquidGlassCompatibility.swift:46-51`: two
stacked materials brighten and desaturate in light mode, flattening the visual
hierarchy. The result reads as "flat and muddy."

Beyond the stacking, visual constants (spacings 4/6/8/10/12/14/16, radii
16/12/10/8/6, opacity tints `Color.primary.opacity(0.06~0.12)`, type sizes) are
hardcoded and duplicated per component, with no shared design system. The accent
color is used inconsistently (Pin gets a flat accent fill; nothing else does).

## Goals

- Adopt Liquid Glass on macOS 26 so the window aligns with system surfaces
  (Spotlight, Control Center, the menu-bar panel already shipped in this app).
- Establish a single token layer for the translation module and apply it
  consistently across every sub-component.
- Eliminate material-on-material stacking on **all** OS versions, so even the
  pre-macOS-26 fallback is cleaner than today.
- Keep the existing layout, behavior, focus/keyboard handling, auto-speak,
  window sizing, and the NSTextView input bridge untouched.

## Non-Goals

- No layout restructure. The chosen structure is **A1 (unified glass shell)**:
  one glass hero surface; result cards become content tiles on that surface, not
  separate glass islands.
- No changes to translation logic, the coordinator, settings, history store,
  keychain, focus management, or keyboard shortcuts.
- No window resize / reposition behavior changes.
- The service editor overlay (`TranslationServiceEditorOverlay.swift`, a Form-based
  config sheet) gets only a light pass to align accent/spacing — its structure is
  not reworked.

## Chosen Approach: A1 — Unified Glass Shell

The window is a single Liquid Glass hero surface (like a system panel). Within it:

- **Small controls float as their own interactive glass** — toolbar buttons,
  language chips, the swap button. Apple's pattern places concentric controls on
  a glass bar, and `LiquidGlassCompatibility.swift:46-51` confirms interactive
  glass capsules composite cleanly over panel glass.
- **The input area is a recessed "well"** — a subtle fill plus a hairline stroke,
  not its own material/glass.
- **Result cards are content tiles** — no own surface; separated by hairline
  dividers and spacing, with a faint hover/expanded tint. This is where the
  double-material is removed.

Rejected alternatives:
- **A2 (floating glass islands):** every card its own glass island in a
  `GlassEffectContainer`. More dazzling and better morphing, but worse text
  readability over busy wallpapers — wrong trade-off for a read-heavy utility.
- **B (single canvas):** drop all per-card surfaces, separate by hairlines only.
  Calmer but loses per-service modular identity.

## Design

### 1. Token layer — new `Views/Translation/TranslationTheme.swift`

A namespace enum of semantic constants plus a few `View` helpers that mirror the
style of the existing `LiquidGlassCompatibility.swift` extensions.

Tokens:

| Category | Token | Value |
|---|---|---|
| Spacing | `windowPadding` | 16 |
| | `sectionGap` | 12 |
| | `tileInsetH` | 14 |
| | `tileInsetV` | 10 |
| | `controlGap` | 8 |
| Radius | `shell` | 16 |
| | `tile` | 12 |
| | `control` | 8 |
| Type | `serviceTitle` | `.subheadline` weight `.semibold` |
| | `bodyText` | `.body` |
| | `meta` | `.caption`, `.secondary` |

Accent rule (documented in the file): the accent color is used **only** for the
Pin active state and primary actions; everything else is `.secondary` or the
glass/material's own tint.

`View` helpers (each gated `#available(macOS 26.0, *)` with a fallback):

- `translationShell()` — window background. macOS 26: `.glassEffect(.regular, in:
  RoundedRectangle(16))`. Fallback: `.regularMaterial` in `RoundedRectangle(16)`
  (today's behavior).
- `translationWell()` — recessed input surface. Both paths: `Color.primary`
  low-opacity fill (~0.04) + hairline stroke in `RoundedRectangle(tile)`. No
  material/glass, so it composites cleanly on both the glass shell and the
  fallback material shell.
- `translationTile(isHovered:isExpanded:)` — result/history content tile.
  Transparent idle; hover ≈ `Color.primary.opacity(0.05)`; expanded ≈ `0.08`.
  Identical on both OS paths. No own material.
- `translationToolbarControl(isActive:)` — small control surface. macOS 26:
  `.glassEffect(.regular.interactive(), …)`, and when active
  `.regular.tint(.accentColor).interactive()`. Fallback: transparent idle +
  hover tint; active = flat accent fill (today's Pin treatment).

### 2. `TranslationView.swift`

- Root: replace `.background(.regularMaterial)` (`:39`) with `.translationShell()`.
  Keep the `.clipShape(RoundedRectangle(16))`.
- Toolbar: wrap the button cluster in `AdaptiveGlassEffectContainer` (already in
  `LiquidGlassCompatibility.swift`). Each button adopts
  `translationToolbarControl(isActive:)`. The Pin button's active branch
  (`:92-97`) switches from a flat accent `RoundedRectangle` fill to the tinted
  interactive glass on macOS 26, keeping the flat accent on the fallback.
- Input card: replace `.thinMaterial, in: RoundedRectangle(12)` (`:167`) with
  `translationWell()`. The NSTextView keeps `drawsBackground = false`; the well is
  drawn by the surrounding SwiftUI, so the editor bridge is untouched. The
  "recognized as" capsule (`:143`) is re-tinted to token values.
- Result spacing migrates to `sectionGap` / hairline dividers handled in the card.

### 3. `LanguageBar.swift`

- The source/target chips and the swap button become small interactive glass
  controls, wrapped in a `GlassEffectContainer` so the swap button between the two
  chips can morph/merge. Fallback keeps the current `Color.primary.opacity` chip
  fills (re-expressed via the token helper).
- Chip padding (`H 11 / V 5`), radii, and the swap circle (28×28) are re-pointed
  at tokens. Keyboard shortcuts (⌘S swap, ⌘P pin) unchanged.

### 4. `TranslationServiceCard.swift` and `AppleTranslationCard.swift`

- Remove `.thinMaterial, in: RoundedRectangle(12)`. The card becomes a content
  tile via `translationTile(isHovered:isExpanded:)`.
- Cards are separated by hairline dividers + `sectionGap` spacing rather than
  each floating as its own material rectangle.
- Header type sizes, status badge, and the speaker/copy/chevron buttons are
  unified to token sizes (`serviceTitle`, `meta`, 12pt glyphs). Expand/collapse
  transition timing standardizes on `.easeInOut(0.2)`.

### 5. `TranslationHistoryView.swift`

- Popover background → `adaptivePanelSurface(cornerRadius:)`.
- History cards: `.thinMaterial, in: RoundedRectangle(10)` → `translationTile(...)`.
- Filter buttons (All / Favorites) re-pointed at tokens; active state follows the
  accent rule.

### 6. `TranslationServiceEditorOverlay.swift` (light pass)

- Align status-label colors, button accent usage, and Form section spacing to the
  token rule. No structural change.

## Surface matrix (summary)

| Element | macOS 26 | Fallback < 26 |
|---|---|---|
| Window shell | `.glassEffect(.regular, RR16)` | `.regularMaterial` RR16 (today) |
| Toolbar buttons | interactive glass in container | transparent + hover tint (no material) |
| Pin active | tinted interactive glass | flat accent fill (today) |
| Input area | recessed well (fill + hairline) | recessed well (fill + hairline) |
| Language chips / swap | interactive glass in container | opacity chips (today, tokenized) |
| Result cards | content tiles (no material) | content tiles (no material) |

The fallback column removes today's `.thinMaterial`-on-`.regularMaterial`
stacking for the input card, result cards, and history cards — a strict
improvement even where Liquid Glass is unavailable.

## Testing & Verification

- Hard gate: `swift build` passes.
- Existing tests continue to pass.
- The dev machine is Darwin 25 (macOS 26), so the glass path is verified visually
  in the running app (`swift run AnyDoor`). The fallback path is verified by
  inspecting each `#available(macOS 26.0, *)` branch.
- Token values are pure constants; no dedicated unit tests added.

## Open Questions

None at design time. Implementation may surface tuning values (exact well-fill and
tile-hover opacities, glass container spacing) to be dialed in against the running
app.
