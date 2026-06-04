# Command Palette Calculator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add inline scientific calculation to the command palette — type an expression, see the result at the top, press Return to copy it.

**Architecture:** A pure, hand-written recursive-descent evaluator (`Sources/AnyDoor/Services/Calculator/`) that never crashes and has no injection surface. The command palette calls `Calculator.evaluate(query:)` inside `filteredSections` and inserts a top "Calculator" section on a hit — structurally identical to the existing Ports dynamic section.

**Tech Stack:** Swift 6.2 (strict concurrency, `.v6` language mode), SwiftUI/AppKit command palette, SPM, XCTest, `Localizable.xcstrings`.

**Spec:** `docs/superpowers/specs/2026-06-04-command-palette-calculator-design.md`

---

## File Structure

**New files (the evaluator unit — pure, `Sendable`, no `@MainActor`):**
- `Sources/AnyDoor/Services/Calculator/CalcToken.swift` — `CalcToken` + `CalcError` enums.
- `Sources/AnyDoor/Services/Calculator/CalcTokenizer.swift` — `String → [CalcToken]`.
- `Sources/AnyDoor/Services/Calculator/CalcFunctions.swift` — whitelisted constants + functions table.
- `Sources/AnyDoor/Services/Calculator/CalcEvaluator.swift` — recursive-descent parser + evaluator.
- `Sources/AnyDoor/Services/Calculator/Calculator.swift` — public facade: detection + evaluate + formatting + `CalcResult`.
- `Tests/AnyDoorTests/CalculatorTests.swift` — unit tests for the whole evaluator unit.

**Modified files (integration):**
- `Sources/AnyDoor/Models/PanelEntry.swift` — add `.calcResult` source case.
- `Sources/AnyDoor/Utilities/L10n.swift` — two new `L10n.Key` cases.
- `Sources/AnyDoor/Resources/Localizable.xcstrings` — two new entries (en + zh-Hans).
- `Sources/AnyDoor/Views/CommandPalettePicker.swift` — `calcSection`, `filteredSections` insert, row subtitle/icon.
- `Sources/AnyDoor/Views/CommandPaletteWindowController.swift` — `commit()` `.calcResult` branch.
- `Tests/AnyDoorTests/CommandPaletteTests.swift` — integration tests for the calc section.

---

## Task 1: Token & error types

**Files:**
- Create: `Sources/AnyDoor/Services/Calculator/CalcToken.swift`

- [ ] **Step 1: Create the token and error types**

Create `Sources/AnyDoor/Services/Calculator/CalcToken.swift`:

```swift
import Foundation

/// A lexical token produced by `CalcTokenizer`.
enum CalcToken: Equatable {
    case number(Double)
    case identifier(String)   // function or constant name, already lowercased
    case plus
    case minus
    case star
    case slash
    case caret
    case percent
    case leftParen
    case rightParen
    case comma
}

/// Internal failure reason. The public `Calculator` facade maps any error to
/// `nil`, so the palette simply shows no calculator section on failure.
enum CalcError: Error, Equatable {
    case empty
    case tooLong
    case tooManyTokens
    case invalidCharacter(Character)
    case malformedNumber(String)
    case unexpectedToken
    case unexpectedEnd
    case unknownIdentifier(String)
    case wrongArity(String)
    case tooDeep
    case notFinite
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds successfully (the new file has no consumers yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Services/Calculator/CalcToken.swift
git commit -m "feat(calc): add token and error types"
```

---

## Task 2: Tokenizer

**Files:**
- Create: `Sources/AnyDoor/Services/Calculator/CalcTokenizer.swift`
- Test: `Tests/AnyDoorTests/CalculatorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AnyDoorTests/CalculatorTests.swift`:

```swift
import XCTest
@testable import AnyDoor

final class CalculatorTests: XCTestCase {

    // MARK: - Tokenizer

    func test_tokenize_numbersOperatorsAndParens() throws {
        let tokens = try CalcTokenizer.tokenize("1 + 2.5 * (3)")
        XCTAssertEqual(tokens, [
            .number(1), .plus, .number(2.5), .star, .leftParen, .number(3), .rightParen
        ])
    }

    func test_tokenize_identifiersWithDigitsAndComma() throws {
        let tokens = try CalcTokenizer.tokenize("log2(8), POW(2,3)")
        XCTAssertEqual(tokens, [
            .identifier("log2"), .leftParen, .number(8), .rightParen, .comma,
            .identifier("pow"), .leftParen, .number(2), .comma, .number(3), .rightParen
        ])
    }

    func test_tokenize_percentAndCaret() throws {
        XCTAssertEqual(try CalcTokenizer.tokenize("8%^2"), [.number(8), .percent, .caret, .number(2)])
    }

    func test_tokenize_emptyThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("   "))
    }

    func test_tokenize_invalidCharacterThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("1 @ 2"))
    }

    func test_tokenize_malformedNumberThrows() {
        XCTAssertThrowsError(try CalcTokenizer.tokenize("1.2.3"))
    }

    func test_tokenize_tooLongThrows() {
        let long = String(repeating: "1", count: 300)
        XCTAssertThrowsError(try CalcTokenizer.tokenize(long))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CalculatorTests`
Expected: FAIL — `CalcTokenizer` is not defined.

- [ ] **Step 3: Implement the tokenizer**

Create `Sources/AnyDoor/Services/Calculator/CalcTokenizer.swift`:

```swift
import Foundation

/// Converts a raw expression string into a flat token stream. Pure; throws
/// `CalcError` on bad input (never raises an Objective-C exception).
enum CalcTokenizer {
    static let maxInputLength = 256
    static let maxTokenCount = 256

    static func tokenize(_ input: String) throws -> [CalcToken] {
        guard input.count <= maxInputLength else { throw CalcError.tooLong }

        var tokens: [CalcToken] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }

            switch c {
            case "+": tokens.append(.plus); i += 1
            case "-": tokens.append(.minus); i += 1
            case "*": tokens.append(.star); i += 1
            case "/": tokens.append(.slash); i += 1
            case "^": tokens.append(.caret); i += 1
            case "%": tokens.append(.percent); i += 1
            case "(": tokens.append(.leftParen); i += 1
            case ")": tokens.append(.rightParen); i += 1
            case ",": tokens.append(.comma); i += 1
            default:
                if c.isNumber || c == "." {
                    var s = ""
                    while i < chars.count, chars[i].isNumber || chars[i] == "." {
                        s.append(chars[i]); i += 1
                    }
                    guard let value = Double(s) else { throw CalcError.malformedNumber(s) }
                    tokens.append(.number(value))
                } else if c.isLetter {
                    var s = ""
                    while i < chars.count, chars[i].isLetter || chars[i].isNumber {
                        s.append(chars[i]); i += 1
                    }
                    tokens.append(.identifier(s.lowercased()))
                } else {
                    throw CalcError.invalidCharacter(c)
                }
            }

            if tokens.count > maxTokenCount { throw CalcError.tooManyTokens }
        }

        guard !tokens.isEmpty else { throw CalcError.empty }
        return tokens
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalculatorTests`
Expected: PASS (all tokenizer tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Calculator/CalcTokenizer.swift Tests/AnyDoorTests/CalculatorTests.swift
git commit -m "feat(calc): add tokenizer"
```

---

## Task 3: Functions & constants table

**Files:**
- Create: `Sources/AnyDoor/Services/Calculator/CalcFunctions.swift`
- Test: `Tests/AnyDoorTests/CalculatorTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CalculatorTests.swift` (inside the class):

```swift
    // MARK: - Functions table

    func test_functions_constants() {
        XCTAssertEqual(CalcFunctions.constants["pi"]!, Double.pi, accuracy: 1e-12)
        XCTAssertEqual(CalcFunctions.constants["e"]!, 2.718281828459045, accuracy: 1e-12)
    }

    func test_functions_unaryApply() throws {
        XCTAssertEqual(try CalcFunctions.apply("sqrt", [9]), 3, accuracy: 1e-12)
        XCTAssertEqual(try CalcFunctions.apply("ln", [2.718281828459045]), 1, accuracy: 1e-9)
        XCTAssertEqual(try CalcFunctions.apply("log", [1000]), 3, accuracy: 1e-12)
        XCTAssertEqual(try CalcFunctions.apply("log10", [1000]), 3, accuracy: 1e-12)
    }

    func test_functions_binaryApply() throws {
        XCTAssertEqual(try CalcFunctions.apply("pow", [2, 10]), 1024, accuracy: 1e-9)
        XCTAssertEqual(try CalcFunctions.apply("min", [3, 5]), 3)
        XCTAssertEqual(try CalcFunctions.apply("max", [3, 5]), 5)
    }

    func test_functions_unknownAndArityThrow() {
        XCTAssertThrowsError(try CalcFunctions.apply("nope", [1]))
        XCTAssertThrowsError(try CalcFunctions.apply("pow", [2]))      // wrong arity
        XCTAssertThrowsError(try CalcFunctions.apply("sqrt", [1, 2]))  // wrong arity
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CalculatorTests`
Expected: FAIL — `CalcFunctions` is not defined.

- [ ] **Step 3: Implement the table**

Create `Sources/AnyDoor/Services/Calculator/CalcFunctions.swift`:

```swift
import Foundation

/// The whitelisted constants and functions the evaluator recognizes. Adding a
/// function is a single-entry edit here. Trig is radian-based.
enum CalcFunctions {
    static let constants: [String: Double] = [
        "pi": Double.pi,
        "e": M_E,
    ]

    /// Apply a named function to its argument list, or throw on unknown
    /// name / wrong arity.
    static func apply(_ name: String, _ args: [Double]) throws -> Double {
        if let fn = unary[name] {
            guard args.count == 1 else { throw CalcError.wrongArity(name) }
            return fn(args[0])
        }
        if let fn = binary[name] {
            guard args.count == 2 else { throw CalcError.wrongArity(name) }
            return fn(args[0], args[1])
        }
        throw CalcError.unknownIdentifier(name)
    }

    private static let unary: [String: @Sendable (Double) -> Double] = [
        "sqrt": { Foundation.sqrt($0) },
        "cbrt": { Foundation.cbrt($0) },
        "abs":  { Swift.abs($0) },
        "ln":   { Foundation.log($0) },        // natural log (base e)
        "log":  { Foundation.log10($0) },      // base-10 log
        "log10": { Foundation.log10($0) },     // alias of log
        "log2": { Foundation.log2($0) },
        "exp":  { Foundation.exp($0) },
        "sin":  { Foundation.sin($0) },
        "cos":  { Foundation.cos($0) },
        "tan":  { Foundation.tan($0) },
        "asin": { Foundation.asin($0) },
        "acos": { Foundation.acos($0) },
        "atan": { Foundation.atan($0) },
        "sinh": { Foundation.sinh($0) },
        "cosh": { Foundation.cosh($0) },
        "tanh": { Foundation.tanh($0) },
        "floor": { Foundation.floor($0) },
        "ceil": { Foundation.ceil($0) },
        "round": { $0.rounded() },
    ]

    private static let binary: [String: @Sendable (Double, Double) -> Double] = [
        "pow": { Foundation.pow($0, $1) },
        "min": { Swift.min($0, $1) },
        "max": { Swift.max($0, $1) },
    ]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalculatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Calculator/CalcFunctions.swift Tests/AnyDoorTests/CalculatorTests.swift
git commit -m "feat(calc): add functions and constants table"
```

---

## Task 4: Evaluator (parser)

**Files:**
- Create: `Sources/AnyDoor/Services/Calculator/CalcEvaluator.swift`
- Test: `Tests/AnyDoorTests/CalculatorTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CalculatorTests.swift` (inside the class). Helper evaluates a string end-to-end through the tokenizer + evaluator:

```swift
    // MARK: - Evaluator

    private func eval(_ s: String) throws -> Double {
        try CalcEvaluator.evaluate(try CalcTokenizer.tokenize(s))
    }

    func test_eval_precedenceAndAssociativity() throws {
        XCTAssertEqual(try eval("2+3*4"), 14, accuracy: 1e-12)
        XCTAssertEqual(try eval("2^3^2"), 512, accuracy: 1e-9)   // right-assoc
        XCTAssertEqual(try eval("-2^2"), -4, accuracy: 1e-12)
        XCTAssertEqual(try eval("2^-2"), 0.25, accuracy: 1e-12)
        XCTAssertEqual(try eval("(-2)^2"), 4, accuracy: 1e-12)
    }

    func test_eval_parensAndUnary() throws {
        XCTAssertEqual(try eval("-(3+4)"), -7, accuracy: 1e-12)
        XCTAssertEqual(try eval("2*(3+4)"), 14, accuracy: 1e-12)
    }

    func test_eval_functionsAndConstants() throws {
        XCTAssertEqual(try eval("sqrt(2)"), 1.4142135623, accuracy: 1e-9)
        XCTAssertEqual(try eval("sin(pi/2)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try eval("ln(e)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try eval("pow(2,10)"), 1024, accuracy: 1e-9)
        XCTAssertEqual(try eval("min(3,5)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try eval("max(3,5)"), 5, accuracy: 1e-12)
    }

    func test_eval_percentLiteral() throws {
        XCTAssertEqual(try eval("50%"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try eval("1234*8%"), 98.72, accuracy: 1e-9)
        XCTAssertEqual(try eval("200+10%"), 200.1, accuracy: 1e-9)
    }

    func test_eval_invalidInputsThrow() {
        XCTAssertThrowsError(try eval("1/0"))       // +Inf → notFinite
        XCTAssertThrowsError(try eval("(1+2)%"))    // percent only follows a number literal
        XCTAssertThrowsError(try eval("pow(2)"))    // wrong arity
        XCTAssertThrowsError(try eval("()"))
        XCTAssertThrowsError(try eval("2 ** abc"))
    }

    func test_eval_tooDeepThrows() {
        let deep = String(repeating: "(", count: 200) + "1" + String(repeating: ")", count: 200)
        XCTAssertThrowsError(try eval(deep))
    }
```

> Note: `1 +` and `sqrt(` are exercised at the facade level in Task 5 (they fail
> tokenizing/parsing and surface as `nil`); here the focus is the parser grammar.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CalculatorTests`
Expected: FAIL — `CalcEvaluator` is not defined.

- [ ] **Step 3: Implement the evaluator**

Create `Sources/AnyDoor/Services/Calculator/CalcEvaluator.swift`:

```swift
import Foundation

/// Recursive-descent parser + evaluator over a `CalcToken` stream.
///
/// Grammar (low → high precedence):
///   expression := term (('+' | '-') term)*
///   term       := unary (('*' | '/') unary)*
///   unary      := ('-' | '+') unary | power
///   power      := primary ('^' unary)?            // right-assoc; exponent may be unary
///   primary    := number ['%'] | identifier ['(' args ')'] | '(' expression ')'
///   args       := expression (',' expression)*
///
/// Percent binds tightest, and only to a number literal, so `(1+2)%` is invalid
/// (the stray `%` is left over and the final all-consumed check fails).
struct CalcEvaluator {
    static let maxDepth = 64

    private let tokens: [CalcToken]
    private var pos = 0
    private var depth = 0

    private init(tokens: [CalcToken]) { self.tokens = tokens }

    /// Evaluate a token stream to a finite `Double`, or throw `CalcError`.
    static func evaluate(_ tokens: [CalcToken]) throws -> Double {
        var parser = CalcEvaluator(tokens: tokens)
        let value = try parser.parseExpression()
        guard parser.pos == parser.tokens.count else { throw CalcError.unexpectedToken }
        guard value.isFinite else { throw CalcError.notFinite }
        return value
    }

    private var current: CalcToken? { pos < tokens.count ? tokens[pos] : nil }
    private mutating func advance() { pos += 1 }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw CalcError.tooDeep }
    }
    private mutating func leave() { depth -= 1 }

    private mutating func parseExpression() throws -> Double {
        try enter(); defer { leave() }
        var value = try parseTerm()
        while let t = current, t == .plus || t == .minus {
            advance()
            let rhs = try parseTerm()
            value = (t == .plus) ? value + rhs : value - rhs
        }
        return value
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parseUnary()
        while let t = current, t == .star || t == .slash {
            advance()
            let rhs = try parseUnary()
            value = (t == .star) ? value * rhs : value / rhs
        }
        return value
    }

    private mutating func parseUnary() throws -> Double {
        if current == .minus { advance(); return -(try parseUnary()) }
        if current == .plus { advance(); return try parseUnary() }
        return try parsePower()
    }

    private mutating func parsePower() throws -> Double {
        let base = try parsePrimary()
        if current == .caret {
            advance()
            let exponent = try parseUnary()
            return pow(base, exponent)
        }
        return base
    }

    private mutating func parsePrimary() throws -> Double {
        try enter(); defer { leave() }
        guard let t = current else { throw CalcError.unexpectedEnd }
        switch t {
        case .number(let v):
            advance()
            if current == .percent { advance(); return v / 100 }
            return v
        case .leftParen:
            advance()
            let inner = try parseExpression()
            guard current == .rightParen else { throw CalcError.unexpectedToken }
            advance()
            return inner
        case .identifier(let name):
            advance()
            return try resolveIdentifier(name)
        default:
            throw CalcError.unexpectedToken
        }
    }

    private mutating func resolveIdentifier(_ name: String) throws -> Double {
        // A constant only when NOT followed by a call paren.
        guard current == .leftParen else {
            if let constant = CalcFunctions.constants[name] { return constant }
            throw CalcError.unknownIdentifier(name)
        }
        advance() // consume '('
        var args: [Double] = []
        if current != .rightParen {
            args.append(try parseExpression())
            while current == .comma {
                advance()
                args.append(try parseExpression())
            }
        }
        guard current == .rightParen else { throw CalcError.unexpectedToken }
        advance()
        return try CalcFunctions.apply(name, args)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalculatorTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Calculator/CalcEvaluator.swift Tests/AnyDoorTests/CalculatorTests.swift
git commit -m "feat(calc): add recursive-descent evaluator"
```

---

## Task 5: Calculator facade (detection + formatting)

**Files:**
- Create: `Sources/AnyDoor/Services/Calculator/Calculator.swift`
- Test: `Tests/AnyDoorTests/CalculatorTests.swift`

- [ ] **Step 1: Add failing tests**

Append to `CalculatorTests.swift` (inside the class):

```swift
    // MARK: - Facade: detection

    func test_facade_bareNumberAndConstantsAreNotDetected() {
        XCTAssertNil(Calculator.evaluate(query: "8080"))
        XCTAssertNil(Calculator.evaluate(query: "5"))
        XCTAssertNil(Calculator.evaluate(query: "pi"))
        XCTAssertNil(Calculator.evaluate(query: "e"))
        XCTAssertNil(Calculator.evaluate(query: "-5"))   // bare negative number
    }

    func test_facade_forcePrefix() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=8080")).copyText, "8080")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=pi")).value, Double.pi, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "=5")).copyText, "5")
    }

    func test_facade_autoDetectExpressions() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1+2")).copyText, "3")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "   2 + 2  ")).copyText, "4")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "pi/2")).value, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "2*e")).value, 2 * M_E, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "sqrt(2)")).value, 1.41421356, accuracy: 1e-7)
    }

    func test_facade_failuresReturnNil() {
        XCTAssertNil(Calculator.evaluate(query: "1 +"))
        XCTAssertNil(Calculator.evaluate(query: "sqrt("))
        XCTAssertNil(Calculator.evaluate(query: "1/0"))
        XCTAssertNil(Calculator.evaluate(query: ""))
        XCTAssertNil(Calculator.evaluate(query: "="))
    }

    // MARK: - Facade: formatting (copyText is locale-independent)

    func test_facade_copyTextFormatting() throws {
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "2+2")).copyText, "4")        // integer, no ".0"
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1/4")).copyText, "0.25")
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "1000*1000")).copyText, "1000000") // no grouping
        XCTAssertEqual(try XCTUnwrap(Calculator.evaluate(query: "10/4")).copyText, "2.5")     // trailing zero trimmed
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CalculatorTests`
Expected: FAIL — `Calculator` is not defined.

- [ ] **Step 3: Implement the facade**

Create `Sources/AnyDoor/Services/Calculator/Calculator.swift`:

```swift
import Foundation

/// One evaluated calculator result surfaced to the command palette.
struct CalcResult: Hashable, Sendable {
    let value: Double      // raw numeric result
    let display: String    // row title: grouped + trailing-zero-trimmed (may localize)
    let copyText: String   // clipboard: locale-independent, no grouping, "." decimal
}

/// Public facade for the command palette: detection + evaluation + formatting.
/// Pure and total — returns `nil` on any failure, never throws, never crashes.
enum Calculator {
    /// Returns a result only when `query` is a calc expression that evaluates.
    /// Honors the `=` force prefix and the auto-detect heuristic.
    static func evaluate(query: String) -> CalcResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let forced = trimmed.hasPrefix("=")
        let body = forced
            ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            : trimmed
        guard !body.isEmpty else { return nil }

        // Auto-detect gate: a non-forced query must look like an expression so
        // bare numbers / constants don't steal command/app/port search.
        if !forced && !looksLikeExpression(body) { return nil }

        guard let tokens = try? CalcTokenizer.tokenize(body),
              let value = try? CalcEvaluator.evaluate(tokens) else { return nil }

        return CalcResult(
            value: value,
            display: format(value, grouping: true, locale: .current),
            copyText: format(value, grouping: false, locale: posixLocale)
        )
    }

    // MARK: - Detection

    /// Cheap structural check: true when the string contains a binary operator,
    /// an opening paren, or a `-` that is not the leading unary sign. Bare
    /// numbers and bare constant names return false.
    static func looksLikeExpression(_ s: String) -> Bool {
        var previousWasOperandEnd = false
        for c in s {
            switch c {
            case "+", "*", "/", "^", "%", "(":
                return true
            case "-":
                if previousWasOperandEnd { return true }
            default:
                break
            }
            if c.isWhitespace { continue }
            previousWasOperandEnd = c.isNumber || c.isLetter || c == ")" || c == "."
        }
        return false
    }

    // MARK: - Formatting

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func format(_ value: Double, grouping: Bool, locale: Locale) -> String {
        let magnitude = abs(value)

        // Integer-valued within range → render without a decimal point.
        if value.rounded() == value && magnitude < 1e15 {
            let f = NumberFormatter()
            f.locale = locale
            f.numberStyle = .decimal
            f.usesGroupingSeparator = grouping
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: value)) ?? String(value)
        }

        // Very large / very small → scientific notation.
        if magnitude != 0 && (magnitude >= 1e15 || magnitude < 1e-10) {
            let f = NumberFormatter()
            f.locale = locale
            f.numberStyle = .scientific
            f.maximumFractionDigits = 10
            f.exponentSymbol = "e"
            return f.string(from: NSNumber(value: value)) ?? String(value)
        }

        // Decimal: up to 10 fractional digits, trailing zeros trimmed.
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouping
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 10
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CalculatorTests`
Expected: PASS (all `CalculatorTests`).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Services/Calculator/Calculator.swift Tests/AnyDoorTests/CalculatorTests.swift
git commit -m "feat(calc): add facade with detection and formatting"
```

---

## Task 6: PanelEntry `.calcResult` source

**Files:**
- Modify: `Sources/AnyDoor/Models/PanelEntry.swift`

- [ ] **Step 1: Add the source case**

In `Sources/AnyDoor/Models/PanelEntry.swift`, add to `enum Source` (after the `portRecord` case):

```swift
        case calcResult(CalcResult)                    // Command-palette-only: evaluated expression
```

- [ ] **Step 2: Add the id mapping**

In `static func id(for source: Source) -> String`, add a case to the switch (after the `portRecord` case):

```swift
        case .calcResult(let result):             return "calc:\(result.copyText)"
```

- [ ] **Step 3: Add the localized title mapping**

In `func localizedTitle() -> String`, add a case to the switch (after the `portRecord` case):

```swift
        case .calcResult(let result): return result.display
```

- [ ] **Step 4: Build to verify it compiles**

Run: `swift build`
Expected: builds (the two `switch`es over `Source` are now exhaustive again).

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Models/PanelEntry.swift
git commit -m "feat(calc): add calcResult panel entry source"
```

---

## Task 7: Localization keys

**Files:**
- Modify: `Sources/AnyDoor/Utilities/L10n.swift`
- Modify: `Sources/AnyDoor/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the two L10n.Key cases**

In `Sources/AnyDoor/Utilities/L10n.swift`, after the line
`case commandPaletteSectionPorts = "commandPalette.section.ports"`, add:

```swift
        case commandPaletteSectionCalculator = "commandPalette.section.calculator"
```

After the line `case toastColorCopied = "toast.color.copied"`, add:

```swift
        case toastCalcCopied = "toast.calc.copied"
```

- [ ] **Step 2: Add the two catalog entries**

Run this script to insert both keys into the xcstrings catalog (keeps valid JSON):

```bash
python3 - <<'PY'
import json
path = "Sources/AnyDoor/Resources/Localizable.xcstrings"
d = json.load(open(path))
def entry(en, zh):
    return {
        "extractionState": "manual",
        "localizations": {
            "en": {"stringUnit": {"state": "translated", "value": en}},
            "zh-Hans": {"stringUnit": {"state": "translated", "value": zh}},
        },
    }
d["strings"]["commandPalette.section.calculator"] = entry("Calculator", "计算")
d["strings"]["toast.calc.copied"] = entry("Copied %@", "已复制 %@")
json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
open(path, "a").write("\n")
print("inserted")
PY
```

- [ ] **Step 3: Verify localization coverage passes**

Run: `swift test --filter LocalizationCoverageTests`
Expected: PASS (both new keys have en + zh-Hans).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Utilities/L10n.swift Sources/AnyDoor/Resources/Localizable.xcstrings
git commit -m "feat(calc): add calculator section and toast strings"
```

---

## Task 8: Command palette calc section

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift`
- Test: `Tests/AnyDoorTests/CommandPaletteTests.swift`

- [ ] **Step 1: Write the failing integration tests**

Append to `Tests/AnyDoorTests/CommandPaletteTests.swift` (inside the `CommandPaletteTests` class):

```swift
    @MainActor
    func testCalcExpressionShowsCalculatorSectionAtTop() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "1+2"

        XCTAssertEqual(state.filteredSections.first?.titleKey, .commandPaletteSectionCalculator)
        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .calcResult(let result) = entry.source else {
            return XCTFail("Expected a calc result entry")
        }
        XCTAssertEqual(result.copyText, "3")
        XCTAssertEqual(entry.title, "3")
        XCTAssertEqual(entry.subtitle, "1+2")
        XCTAssertEqual(entry.symbol, "function")
    }

    @MainActor
    func testForcePrefixCalculatesBareNumber() throws {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "=8080"

        let entry = try XCTUnwrap(state.flatEntries.first)
        guard case .calcResult(let result) = entry.source else {
            return XCTFail("Expected a calc result entry")
        }
        XCTAssertEqual(result.copyText, "8080")
    }

    @MainActor
    func testBareNumberDoesNotShowCalculatorSection() {
        let state = CommandPaletteState(sections: [], hyperFlags: 0)
        state.query = "8080"

        XCTAssertFalse(state.filteredSections.contains { $0.titleKey == .commandPaletteSectionCalculator })
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CommandPaletteTests`
Expected: FAIL — `commandPaletteSectionCalculator` section is never produced.

- [ ] **Step 3: Add `calcSection` and wire it into `filteredSections`**

In `Sources/AnyDoor/Views/CommandPalettePicker.swift`, in `CommandPaletteState`, modify `filteredSections` so the calculator section is inserted at the very top (above ports). Replace:

```swift
        if let ports = portSection(matching: trimmed) {
            sections.insert(ports, at: 0)
        }
        return sections
```

with:

```swift
        if let ports = portSection(matching: trimmed) {
            sections.insert(ports, at: 0)
        }
        if let calc = calcSection(matching: trimmed) {
            sections.insert(calc, at: 0)
        }
        return sections
```

Then add this method to `CommandPaletteState` (next to `portSection(matching:)`):

```swift
    /// Builds a one-row "Calculator" section when `query` is a calc expression.
    /// Inserted at the top of `filteredSections`, so it is selected by default
    /// and Return copies the result immediately.
    private func calcSection(matching query: String) -> CommandPaletteSection? {
        guard let result = Calculator.evaluate(query: query) else { return nil }
        let entry = PanelEntry(
            id: PanelEntry.id(for: .calcResult(result)),
            source: .calcResult(result),
            displayOrder: 0,
            isVisible: true,
            hotkey: nil,
            title: result.display,
            subtitle: query.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: "function",
            kind: .action,
            toggleState: nil,
            permission: .notRequired
        )
        return CommandPaletteSection(titleKey: .commandPaletteSectionCalculator, entries: [entry])
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CommandPaletteTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPalettePicker.swift Tests/AnyDoorTests/CommandPaletteTests.swift
git commit -m "feat(calc): show calculator section in command palette"
```

---

## Task 9: Row rendering for calc results

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPalettePicker.swift`

- [ ] **Step 1: Show the subtitle for calc rows**

In `CommandPaletteRow.titleBlock`, replace the port-only subtitle condition:

```swift
            if case .portRecord = entry.source,
               let subtitle = entry.subtitle,
               !subtitle.isEmpty {
```

with a shared check:

```swift
            if showsSubtitle, let subtitle = entry.subtitle, !subtitle.isEmpty {
```

Then add this computed property to `CommandPaletteRow`:

```swift
    /// Port records and calculator results both render their subtitle (the port
    /// detail line, or the original expression for a calc result).
    private var showsSubtitle: Bool {
        switch entry.source {
        case .portRecord, .calcResult: return true
        default: return false
        }
    }
```

- [ ] **Step 2: Keep `iconPath` exhaustive (SF Symbol for calc rows)**

In `CommandPaletteRow.iconPath`, add `.calcResult` to the symbol (nil-path) case. Replace:

```swift
        case .builtin, .portRecord:
            return nil
```

with:

```swift
        case .builtin, .portRecord, .calcResult:
            return nil
```

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build`
Expected: builds (the `iconPath` switch over `Source` is exhaustive again).

- [ ] **Step 4: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPalettePicker.swift
git commit -m "feat(calc): render expression subtitle on calculator rows"
```

---

## Task 10: Commit action — copy result

**Files:**
- Modify: `Sources/AnyDoor/Views/CommandPaletteWindowController.swift`

- [ ] **Step 1: Handle `.calcResult` in `commit`**

In `Sources/AnyDoor/Views/CommandPaletteWindowController.swift`, in `private func commit(_ entry: PanelEntry)`, add a case to the `switch entry.source` (after the `.portRecord` case):

```swift
        case .calcResult(let result):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.copyText, forType: .string)
            // Suppress clipboard-history capture, matching every other internal
            // copy path (PickColor / OCR / QRCode / Screenshot).
            ClipboardWatcher.shared?.noteSelfWrite(changeCount: pasteboard.changeCount)
            ToastPresenter.shared.show(.success(L(.toastCalcCopied, result.display)))
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: builds (the `commit` switch over `Source` is exhaustive again).

- [ ] **Step 3: Commit**

```bash
git add Sources/AnyDoor/Views/CommandPaletteWindowController.swift
git commit -m "feat(calc): copy result to clipboard on commit"
```

---

## Task 11: Full verification & manual smoke test

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: PASS — all tests green, including `CalculatorTests`, `CommandPaletteTests`, `LocalizationCoverageTests`.

- [ ] **Step 2: Build a runnable binary**

Run: `swift build`
Expected: builds with no warnings from the new files.

- [ ] **Step 3: Manual smoke test**

Run: `swift run AnyDoor` (grant Accessibility if prompted), open the command palette via its hotkey, and verify:
- Typing `1+2` shows a top "Calculator" / "计算" section with `3` and subtitle `1+2`.
- `1234*8%` → `98.72`; `sqrt(2)` → `1.4142135624`; `sin(pi/2)` → `1`; `2^10` → `1024`.
- `1000*1000` displays grouped (`1,000,000`) but copies plain (`1000000`).
- `=8080` shows `8080`; plain `8080` shows only the Ports section (no Calculator).
- `pi` alone does **not** show a Calculator section; `=pi` does.
- Pressing Return copies the result, closes the palette, and shows a "Copied …" toast.
- The copied value does **not** appear in clipboard history.

- [ ] **Step 4: Final integration commit (if any uncommitted changes remain)**

```bash
git status
# If clean, nothing to do. Otherwise:
git add -A
git commit -m "test(calc): verify calculator end-to-end"
```

---

## Self-Review Notes

**Spec coverage:**
- Evaluator unit (tokenizer/parser/functions/facade) → Tasks 1–5.
- `=` force prefix + auto-detect heuristic + bare-constant exclusion → Task 5 (+ tests).
- Scientific function/constant set, radians, `^` right-assoc, percent literal → Tasks 3–4 (+ tests).
- Performance guards (length / token count / recursion depth) → Tasks 2 & 4 (+ tests).
- `PanelEntry.calcResult` + id + title → Task 6.
- L10n section title + toast (en/zh-Hans) → Task 7.
- Top-of-palette section insertion + default selection → Task 8.
- Row subtitle (expression) + SF Symbol `function` → Task 9.
- Commit copies locale-independent `copyText`, `noteSelfWrite`, toast → Task 10.
- Number formatting (display grouped / copy plain POSIX, integer & decimal & scientific) → Task 5 (+ tests).

**Type consistency:** `CalcToken`, `CalcError`, `CalcFunctions.apply/constants`, `CalcEvaluator.evaluate`, `Calculator.evaluate(query:)`, `CalcResult(value/display/copyText)`, and `PanelEntry.Source.calcResult` are used identically across all tasks.

**No placeholders:** every code step contains full code; every run step states the exact command and expected result.
```
