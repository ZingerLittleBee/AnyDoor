import Foundation

/// Presentation unit for a Target Size limit. Finder-style decimal units:
/// 1 KB = 1,000 bytes, 1 MB = 1,000,000 bytes.
enum TargetSizeUnit: String, CaseIterable, Sendable {
    case kb
    case mb

    var bytesPerUnit: Int64 {
        switch self {
        case .kb: return 1_000
        case .mb: return 1_000_000
        }
    }
}

/// A Per-Output Limit for Target Size compression. `bytes` is the exact integer
/// byte budget the final file must not exceed; `unit` is presentation only and
/// never alters the effective limit.
struct TargetSizeLimit: Hashable, Sendable {
    let bytes: Int64
    let unit: TargetSizeUnit

    /// Decimal upper bound on any limit: 1 TB (1,000,000,000,000 bytes).
    static let maxBytes: Int64 = 1_000_000_000_000

    /// Parse localized positive decimal input into an exact byte limit.
    ///
    /// Accepts up to two fractional digits and tolerates surrounding whitespace.
    /// Both ASCII "." and the locale's decimal separator are accepted, because
    /// users routinely paste ASCII decimals regardless of their locale; group
    /// separators and sign characters are rejected. Byte derivation uses exact
    /// decimal arithmetic so no binary floating-point error can reach `bytes`.
    static func parse(_ text: String, unit: TargetSizeUnit, locale: Locale) throws -> TargetSizeLimit {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TargetSizeLimitParseError.empty }

        // Normalize both the ASCII point and the locale separator to a canonical
        // "." so a single Decimal parse covers every accepted separator.
        let localeSeparator = locale.decimalSeparator ?? "."
        var normalized = trimmed
        if localeSeparator != "." {
            normalized = normalized.replacingOccurrences(of: localeSeparator, with: ".")
        }

        // Only ASCII digits and at most one canonical "." are permitted. This
        // rejects group separators, signs, letters and repeated separators.
        guard normalized.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else {
            throw TargetSizeLimitParseError.malformed
        }
        let separatorCount = normalized.filter { $0 == "." }.count
        guard separatorCount <= 1 else { throw TargetSizeLimitParseError.malformed }

        // Enforce the two-fraction-digit contract before evaluating magnitude.
        if let dotIndex = normalized.firstIndex(of: ".") {
            let fraction = normalized[normalized.index(after: dotIndex)...]
            if fraction.count > 2 { throw TargetSizeLimitParseError.tooManyFractionDigits }
            // A bare "." or a value with no integer and no fraction is garbage.
            if normalized.count == 1 { throw TargetSizeLimitParseError.malformed }
        }

        let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX"))
        guard let decimal, decimal.isFinite else { throw TargetSizeLimitParseError.malformed }
        guard decimal > 0 else { throw TargetSizeLimitParseError.nonPositive }

        // value × bytesPerUnit is an exact integer for ≤2 fraction digits since
        // bytesPerUnit ≥ 1000; round to be defensive, never to correct error.
        let product = decimal * Decimal(unit.bytesPerUnit)
        var rounded = Decimal()
        var mutableProduct = product
        NSDecimalRound(&rounded, &mutableProduct, 0, .plain)

        // Bound-check as Decimal before narrowing: int64Value on a value past
        // Int64.max can wrap and would sneak under maxBytes.
        guard rounded <= Decimal(maxBytes) else { throw TargetSizeLimitParseError.overflow }
        let bytes = (rounded as NSDecimalNumber).int64Value
        guard bytes > 0 else { throw TargetSizeLimitParseError.nonPositive }

        return TargetSizeLimit(bytes: bytes, unit: unit)
    }

    /// Switch the presentation unit. `bytes` — the effective limit — is a product
    /// contract and never changes; only `unit` does.
    func converted(to newUnit: TargetSizeUnit) -> TargetSizeLimit {
        TargetSizeLimit(bytes: bytes, unit: newUnit)
    }

    /// The number to show in the text field for the current unit: `bytes` divided
    /// by `bytesPerUnit`, plain-rounded to at most two fraction digits, formatted
    /// with the locale's decimal separator, no grouping, trailing zeros trimmed.
    /// Rounding affects display only, never `bytes`.
    func displayValue(locale: Locale) -> String {
        let value = Decimal(bytes) / Decimal(unit.bytesPerUnit)
        var rounded = Decimal()
        var mutableValue = value
        NSDecimalRound(&rounded, &mutableValue, 2, .plain)

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: rounded as NSDecimalNumber) ?? "0"
    }
}

enum TargetSizeLimitParseError: Error, Equatable {
    case empty
    case malformed
    case tooManyFractionDigits
    case nonPositive
    case overflow
}
