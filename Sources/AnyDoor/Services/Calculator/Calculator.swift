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
