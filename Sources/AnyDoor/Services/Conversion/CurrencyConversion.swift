import Foundation

/// Pure, total currency converter for the command palette. Converts
/// `"<amount> <codeA> (to|in) <codeB>"` against an injected `RateTable`. Returns
/// an empty array when rates are unavailable, a code is unknown, or the query
/// does not parse. Never throws.
///
/// `detail` carries the bare rate date (`"2026-06-13"`); the palette wraps it in
/// a localized `"as of …"` subtitle, keeping this core free of localization.
enum CurrencyConversion {
    static func detect(_ query: String, rates: RateTable?) -> [ConversionResult] {
        guard let rates else { return [] }
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return [] }

        guard let (lhs, rhs) = split(lowered) else { return [] }
        guard let (amount, sourceCode) = parseAmountAndCode(lhs),
              let targetCode = parseCode(rhs) else { return [] }
        guard let sourceRate = rates.rate(for: sourceCode),
              let targetRate = rates.rate(for: targetCode) else { return [] }
        // A zero/negative rate (only reachable via a corrupted cache) would divide
        // to Infinity/NaN; decline rather than copy a nonsense value. Mirrors
        // CalcEvaluator's `value.isFinite` guard.
        guard sourceRate > 0, targetRate > 0 else { return [] }

        let value = amount * targetRate / sourceRate
        guard value.isFinite else { return [] }
        let number = Self.format(value)
        return [ConversionResult(
            kind: .currency,
            value: value,
            display: "\(number) \(targetCode)",
            copyText: number,
            detail: rates.date,
            symbol: "dollarsign.circle"
        )]
    }

    // MARK: - Parsing

    private static let symbols: [(String, String)] = [("$", "USD"), ("€", "EUR"), ("£", "GBP")]

    /// Splits on a connector: " to " (preferred), " in ", or "=" (with or without
    /// surrounding spaces, so "100 usd = rmb" and "100 usd=rmb" both work).
    private static func split(_ s: String) -> (String, String)? {
        for separator in [" to ", " in ", "="] {
            if let range = s.range(of: separator) {
                return (String(s[..<range.lowerBound]), String(s[range.upperBound...]))
            }
        }
        return nil
    }

    /// Parses an amount with its currency: `"100 usd"`, `"100usd"`, `"$100"`,
    /// `"100$"`, `"€50"`, `"1,000 usd"`.
    private static func parseAmountAndCode(_ side: String) -> (Double, String)? {
        var str = side.trimmingCharacters(in: .whitespaces)
        var symbolCode: String?
        for (sym, code) in symbols {
            if str.hasPrefix(sym) { symbolCode = code; str.removeFirst(); break }
            if str.hasSuffix(sym) { symbolCode = code; str.removeLast(); break }
        }
        str = str.trimmingCharacters(in: .whitespaces)

        let numericPrefix = String(str.prefix { $0.isNumber || $0 == "." || $0 == "," })
        // Commas are accepted only as US-style thousands grouping; an ambiguous
        // comma-decimal like "1,5" is rejected rather than silently read as 15.
        if numericPrefix.contains(",") && !Self.isValidGrouping(numericPrefix) { return nil }
        let amountString = numericPrefix.replacingOccurrences(of: ",", with: "")
        guard let amount = Double(amountString) else { return nil }
        let rest = str.dropFirst(numericPrefix.count).trimmingCharacters(in: .whitespaces)

        if let symbolCode {
            guard rest.isEmpty else { return nil }
            return (amount, symbolCode)
        }
        guard let code = currencyCode(String(rest)) else { return nil }
        return (amount, code)
    }

    /// Parses a target currency from a code or a symbol.
    private static func parseCode(_ side: String) -> String? {
        let token = side.trimmingCharacters(in: .whitespaces)
        if let symbol = symbols.first(where: { $0.0 == token }) { return symbol.1 }
        return currencyCode(token)
    }

    /// True when commas form valid US thousands grouping (e.g. "1,000",
    /// "12,345,678", "1,000.50") — rejecting "1,5" and "1,00,000".
    private static func isValidGrouping(_ s: String) -> Bool {
        s.range(of: #"^\d{1,3}(,\d{3})+(\.\d+)?$"#, options: .regularExpression) != nil
    }

    /// Common colloquial currency names → ISO code (the query is already
    /// lowercased upstream). Lets people type "rmb"/"yuan"/"euro" instead of the
    /// ISO code. Only unambiguous names are included; "dollar" defaults to USD.
    private static let nameAliases: [String: String] = [
        "rmb": "CNY", "yuan": "CNY",
        "yen": "JPY",
        "euro": "EUR", "euros": "EUR",
        "pound": "GBP", "pounds": "GBP", "quid": "GBP", "sterling": "GBP",
        "dollar": "USD", "dollars": "USD", "buck": "USD", "bucks": "USD",
        "won": "KRW",
        "franc": "CHF", "francs": "CHF",
        "rupee": "INR", "rupees": "INR",
    ]

    /// A colloquial currency name or a bare 3-letter alphabetic ISO code
    /// (uppercased), or nil. Aliases win so "rmb" maps to CNY, not the literal "RMB".
    private static func currencyCode(_ token: String) -> String? {
        if let alias = nameAliases[token] { return alias }
        guard token.count == 3, token.allSatisfy(\.isLetter) else { return nil }
        return token.uppercased()
    }

    // MARK: - Formatting

    /// Fixed 2 fractional digits, no grouping, "." decimal.
    static func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
}
