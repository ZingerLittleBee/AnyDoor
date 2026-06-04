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
├── CalcToken.swift       # Token enum: number, operator, paren, comma, identifier, percent
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
  - (a) cheap `looksLikeExpression` heuristic passes — the query contains an
    operator (`+ * / ^ %`, or a `-` not in leading-unary position), or a `(`, or
    a **function call** (a known function name immediately followed by `(`). The
    heuristic keys on operator/paren structure, **not** on a bare name being
    present. This excludes a bare port number `8080`, a lone number `5`, and —
    importantly — a bare constant `pi` or `e` (which must not steal command/app
    search). `pi/2`, `2*pi`, `sin(`, `sqrt(2)` auto-trigger because they carry an
    operator or a function-call paren.
  - (b) evaluation succeeds.
  If either fails → no section (silent hide; consistent with "parse failure is
  quiet" decision).
  - To compute a **bare constant** on its own, use the force prefix: `=pi`, `=e`.

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
  - `^` is **right-associative**, and its right operand accepts a unary minus:
    `2^3^2` = `2^(3^2)` = 512; `2^-2` = 0.25; `(-2)^2` = 4.
- **Percentage literal:** `%` is a **postfix on a number literal only**, meaning
  "÷ 100". `50%` = 0.5; `1234 * 8%` = 98.72; `200 + 10%` = 200.1. A `%` after
  anything other than a number literal is invalid: `(1+2)%` does **not** parse
  (→ no section). (Contextual `200 + 10%` = 220 is **explicitly excluded**.)
- **Constants:** `pi`, `e`.
- **Functions (radians):**
  - Unary: `sqrt cbrt abs ln log log10 log2 exp sin cos tan asin acos atan sinh cosh tanh floor ceil round`
  - `ln` = natural log (base *e*); `log` = base-10 log; `log10` is an alias of `log`.
  - Binary: `pow(x, y)`, `min(a, b)`, `max(a, b)` — require a `,` token in the
    tokenizer to separate arguments.
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
   - Calc entry: `symbol: "function"`, `title` = display, `subtitle` = the
     original expression, `kind: .action`.

3. **`CommandPaletteRow`** (`Views/CommandPalettePicker.swift`) — extend the
   subtitle-rendering condition (currently `case .portRecord`) to also cover
   `.calcResult`, so the original expression shows as the row subtitle.
   `iconPath` returns `nil` for `.calcResult` → SF Symbol path.

4. **`commit()`** (`Views/CommandPaletteWindowController.swift`) — add
   `.calcResult` case:
   - `pasteboard.clearContents()` then `setString(result.copyText, forType: .string)`.
   - **Immediately** call `ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)`
     so the result is **not** recorded in clipboard history — matching every
     other internal copy path (PickColor / OCR / QRCode / Screenshot all do this).
   - `close()` (already called at top of `commit`), then
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
  The display formatter may localize the grouping/decimal symbols.
- **Copy** (`copyText`): **locale-independent** — fixed `.` decimal separator, no
  grouping separators, so it pastes cleanly into other fields and reproduces
  across locales. Build it with a fixed `Locale(identifier: "en_US_POSIX")` (or
  plain `String`/`Decimal` formatting). Do **not** share a mutable `static`
  `NumberFormatter` between the display and copy paths — under Swift 6 strict
  concurrency a shared mutable formatter is not cleanly `Sendable`; construct
  formatters locally (or keep them as `let` POSIX-locale instances).

## Performance & Safety Guards

`Calculator.evaluate(query:)` runs on the **main thread**, synchronously, on every
keystroke (inside `filteredSections`). To keep it cheap and bounded:

- **Input length cap:** reject (return `nil`) when the trimmed query exceeds a max
  length (e.g. 256 chars) before tokenizing.
- **Token count cap:** bail out if the token stream exceeds a max count.
- **Recursion depth cap:** the recursive-descent parser tracks depth and fails
  (returns `nil`) past a limit (e.g. 64), so pathological nesting `((((…))))`
  cannot blow the stack.
- All guards fail **silently** (no section), consistent with the quiet-failure rule.

## Testing (TDD)

The evaluator is a pure function — write tests first. Add to existing
`Tests/AnyDoorTests/` (likely extend `CommandPaletteTests.swift` for integration
and add a `CalculatorTests.swift` for the unit).

**Evaluator unit:**
- Precedence & associativity: `2+3*4` = 14, `2^3^2` = 512 (right-assoc),
  `-2^2` = -4, `2^-2` = 0.25, `(-2)^2` = 4.
- Parentheses & unary minus: `-(3+4)` = -7, `2*(3+4)` = 14.
- Functions: `sqrt(2)` ≈ 1.41421356, `sin(pi/2)` = 1, `ln(e)` = 1,
  `log(1000)` = 3, `log10(1000)` = 3, `pow(2,10)` = 1024, `min(3,5)` = 3, `max(3,5)` = 5.
- Constants: `pi`, `e`.
- Percentage literal: `50%` = 0.5, `1234*8%` = 98.72, `200+10%` = 200.1;
  `(1+2)%` → nil (invalid: `%` only follows a number literal).
- Failure → nil: `1/0`, `sqrt(`, `1 +`, `2 ** abc`, empty, `()`, `pow(2)` (arity).
- Non-finite → nil: results that produce `NaN`/`Inf`.
- Guard limits → nil: over-long input, over-deep nesting `((((…))))`.

**Formatting:**
- Integer vs decimal, trailing-zero trim, thousands grouping, scientific fallback,
  `display` vs `copyText` divergence.

**Detection:**
- `8080` → nil (no calc), `=8080` → 8080, `5` → nil, `1+2` → 3, `sqrt(2)` → ≈1.414,
  `   2 + 2  ` (whitespace) → 4.
- Bare constants do **not** auto-trigger: `pi` → nil, `e` → nil; but `=pi` → ≈3.14159,
  `pi/2` → ≈1.5708, `2*e` → ≈5.4366.

## Out of Scope / Future

- Unit conversion and currency (separate specs).
- Result history, variables, contextual percentage.
```
