# Command Palette Calculator — Design

**Date:** 2026-06-04
**Status:** Approved, ready for implementation planning

## Summary

Add inline scientific calculation to the command palette. When the user types a
math expression (e.g. `sqrt(2)+1`, `1234 * 8%`, `2^10`), a dedicated **Calculator**
section appears at the very top of the palette showing the evaluated result.
Pressing Return (or clicking the row) copies the result to the clipboard, closes
the palette, and shows a confirmation toast — mirroring the existing port-kill UX.

Scope: arithmetic + scientific functions/constants. **No unit conversion, no
currency** (those are deferred as separate future projects with their own
network/cache lifecycle).

## Goals

- Type an expression, see the result instantly, copy with one keystroke.
- Fully offline, zero dependencies, zero network.
- **Never crash** on any intermediate/invalid keystroke (live per-keystroke input).
- **No injection risk** (no arbitrary Objective-C selector evaluation).
- Cleanly unit-testable as a pure function (TDD-first).

## Non-Goals

- Unit conversion (`10 km to mile`) — future project.
- Currency / exchange rates — future project.
- Contextual percentage (`200 + 10%` = 220) — explicitly excluded as too magic.
- Variables, assignment, multi-line, or history of past results.

## Architecture

The feature plugs into the existing command-palette "dynamic section" mechanism,
structurally identical to the **Ports** section (`CommandPalettePicker.swift`'s
`portSection(matching:)`). A new pure-function evaluator unit is the only
substantial new code; the rest is small integration edits.

```
User keystroke
  → CommandPaletteState.filteredSections (existing)
      ├─ Calculator.evaluate(query:)        ← NEW pure unit
      │     hit → insert Calculator section at index 0 (top)
      ├─ portSection(matching:)             (existing)
      └─ command / app sections             (existing, query-filtered)
```

### Why a hand-written evaluator (not `NSExpression`)

Rejected `NSExpression(format:)` for two disqualifying reasons in this
always-on, per-keystroke context:

1. **Crash risk** — `NSExpression(format:)` raises uncaught Objective-C
   exceptions on malformed input that Swift `try/catch` cannot intercept.
   Live input produces constant malformed intermediate states.
2. **Injection risk** — `FUNCTION(obj, 'selector')` can invoke arbitrary methods.

A small recursive-descent evaluator returns a Swift optional/`Result`, never
throws an Obj-C exception, evaluates only a fixed whitelisted grammar, and is
trivially unit-tested.

## New Unit: Calculator (`Sources/AnyDoor/Services/Calculator/`)

Pure computation. No `@MainActor`. `Sendable`. Well-bounded, fully unit-testable.

```
Calculator/
├── CalcToken.swift       # Token enum: number, operator, paren, identifier, percent
├── CalcTokenizer.swift   # String → [CalcToken]; throws CalcError on bad input
├── CalcEvaluator.swift   # Recursive-descent parser + evaluator → Double
└── Calculator.swift      # Public facade: detection + evaluate + formatting
```

### Public API (the only entry point consumers touch)

```swift
struct CalcResult: Hashable, Sendable {
    let value: Double      // raw numeric result
    let display: String    // row title: grouped + trailing-zero-trimmed, e.g. "1,234.5"
    let copyText: String   // clipboard: plain, no grouping, e.g. "1234.5"
}

enum Calculator {
    /// Returns a result ONLY when `query` is a calc expression that evaluates.
    /// Honors the `=` force prefix and the auto-detect heuristic.
    /// Returns nil on any failure — never throws, never crashes.
    static func evaluate(query: String) -> CalcResult?
}
```

`CalcError` is internal to the unit; the facade swallows it and returns `nil`.

## Detection Logic (when the Calculator section appears)

Implemented inside `Calculator.evaluate(query:)`:

- **`=` force prefix** — query (trimmed) starts with `=`: strip the `=`, evaluate
  the remainder, bypassing the heuristic. `=8080` → shows `8080`. Does **not**
  conflict with ports: the port needle requires an all-numeric string, and the
  leading `=` fails that test, so the ports section never appears for `=…`.
- **Auto-detect (no prefix)** — show the section only when **both** hold:
  - (a) cheap `looksLikeExpression` heuristic passes — contains an operator
    (`+ * / ^`, or a `-` not in leading-unary position), or `(`, or a known
    function/constant name. This excludes a bare port number `8080` and a lone
    number `5`.
  - (b) evaluation succeeds.
  If either fails → no section (silent hide; consistent with "parse failure is
  quiet" decision).

### Interaction with the Ports section

Clean separation by construction:

| Input    | Ports section            | Calculator section |
|----------|--------------------------|--------------------|
| `8080`   | yes (numeric needle)     | no (no operator)   |
| `=8080`  | no (`=` breaks numeric needle) | yes (`8080`) |
| `80+80`  | no (not all-numeric)     | yes (`160`)        |
| `5`      | yes, if a process listens on 5 | no (bare number) |

A bare number is always a port query, never a calculation: the Calculator
section deliberately ignores bare numbers (no operator/function/paren), so a lone
`5` or `8080` routes only to ports. Use `=5` to force calculation of a bare
number.

## Supported Grammar (scientific set)

- **Operators:** `+ - * / ^` (`^` = exponent), unary minus, parentheses.
  - Precedence (low → high): `+ -` < `* /` < unary `-` < `^`. So `-2^2` = `-(2^2)` = -4.
  - `^` is **right-associative**: `2^3^2` = `2^(3^2)` = 512.
- **Percentage literal:** a number followed by `%` means "÷ 100".
  `1234 * 8%` → `98.72`. (Contextual `200 + 10%` = 220 is **excluded**.)
- **Constants:** `pi`, `e`.
- **Functions (radians):**
  - Unary: `sqrt cbrt abs ln log log2 exp sin cos tan asin acos atan sinh cosh tanh floor ceil round`
  - Binary: `pow(x, y)`, `min(a, b)`, `max(a, b)`
- The function/constant set lives in a single lookup table; adding functions is a
  one-table edit.
- **Trig uses radians** (`sin(pi/2)` = 1) — mathematically consistent, clean impl.

## Data Flow / Integration Points

1. **`PanelEntry.Source`** (`Models/PanelEntry.swift`) — add
   `case calcResult(CalcResult)` (command-palette-only, like `.portRecord`).
   - `id(for:)` → `"calc:\(result.copyText)"`.
   - `localizedTitle()` → returns `result.display`.
   - `CalcResult` is `Hashable`, so `Source`/`PanelEntry` stay `Hashable`.

2. **`CommandPaletteState`** (`Views/CommandPalettePicker.swift`) — add
   `calcSection(matching:)` building one entry; in `filteredSections`,
   `sections.insert(calc, at: 0)` (above ports). Because `selectedIndex` resets
   to 0 on query change (existing `onChange`), the calc row is selected by
   default → Return copies immediately.
   - Calc entry: `symbol: "function"` (or `"equal.square"`), `title` = display,
     `subtitle` = the original expression, `kind: .action`.

3. **`CommandPaletteRow`** (`Views/CommandPalettePicker.swift`) — extend the
   subtitle-rendering condition (currently `case .portRecord`) to also cover
   `.calcResult`, so the original expression shows as the row subtitle.
   `iconPath` returns `nil` for `.calcResult` → SF Symbol path.

4. **`commit()`** (`Views/CommandPaletteWindowController.swift`) — add
   `.calcResult` case: write `copyText` to `NSPasteboard.general`, `close()`
   (already called at top of `commit`), then
   `ToastPresenter.shared.show(.success(L(.toastCalcCopied, result.display)))`.

5. **Localization** (`Utilities/L10n.swift` + `Resources/Localizable.xcstrings`) —
   add two keys with both `en` and `zh-Hans` entries (and any other locales the
   catalog already carries, to satisfy `LocalizationCoverageTests`):
   - `commandPalette.section.calculator` → "Calculator" / "计算"
   - `toast.calc.copied` → "Copied %@" / "已复制 %@"

## Error Handling & Number Formatting

- Division by zero, `NaN`, `±Inf`, invalid, or incomplete input → `nil` (section
  absent). The evaluator guards `value.isFinite` before returning.
- **Display** (`display`): integers render without a decimal (`4`, not `4.0`);
  decimals to ~10 significant digits with trailing zeros trimmed; thousands
  grouping applied; very large/small magnitudes fall back to scientific notation.
- **Copy** (`copyText`): plain numeric string, no grouping separators, so it
  pastes cleanly into other fields.

## Testing (TDD)

The evaluator is a pure function — write tests first. Add to existing
`Tests/AnyDoorTests/` (likely extend `CommandPaletteTests.swift` for integration
and add a `CalculatorTests.swift` for the unit).

**Evaluator unit:**
- Precedence & associativity: `2+3*4` = 14, `2^3^2` (define & test associativity),
  `-2^2`.
- Parentheses & unary minus: `-(3+4)`, `2*(3+4)`.
- Functions: `sqrt(2)` ≈ 1.41421356, `sin(pi/2)` = 1, `log(1000)` = 3, `pow(2,10)` = 1024.
- Constants: `pi`, `e`.
- Percentage literal: `50%` = 0.5, `1234*8%` = 98.72.
- Failure → nil: `1/0`, `sqrt(` , `1 +`, `2 ** abc`, empty, `()`.
- Non-finite → nil: results that produce `NaN`/`Inf`.

**Formatting:**
- Integer vs decimal, trailing-zero trim, thousands grouping, scientific fallback,
  `display` vs `copyText` divergence.

**Detection:**
- `8080` → nil (no calc), `=8080` → 8080, `5` → nil, `1+2` → 3, `sqrt(2)` → ≈1.414,
  `   2 + 2  ` (whitespace) → 4.

## Out of Scope / Future

- Unit conversion and currency (separate specs).
- Result history, variables, contextual percentage.
```
