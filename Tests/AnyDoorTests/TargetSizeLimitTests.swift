import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

// Separator rule under test: parse accepts BOTH the ASCII "." and the locale's
// decimal separator. Under a comma-separator locale (fr_FR) "1,5" and "1.5" both
// mean 1.5; under en_US the locale separator is "." so a comma is malformed.
final class TargetSizeLimitTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let frFR = Locale(identifier: "fr_FR")

    // MARK: - parse: valid values

    func testParseWholeMegabyte() throws {
        let limit = try TargetSizeLimit.parse("1", unit: .mb, locale: enUS)
        XCTAssertEqual(limit.bytes, 1_000_000)
        XCTAssertEqual(limit.unit, .mb)
    }

    func testParseFractionalKilobyte() throws {
        let limit = try TargetSizeLimit.parse("1.5", unit: .kb, locale: enUS)
        XCTAssertEqual(limit.bytes, 1_500)
    }

    func testParseQuarterMegabyte() throws {
        let limit = try TargetSizeLimit.parse("0.25", unit: .mb, locale: enUS)
        XCTAssertEqual(limit.bytes, 250_000)
    }

    func testParseTwoFractionDigitsKilobyte() throws {
        let limit = try TargetSizeLimit.parse("0.01", unit: .kb, locale: enUS)
        XCTAssertEqual(limit.bytes, 10)
    }

    func testParseToleratesWhitespace() throws {
        let limit = try TargetSizeLimit.parse("  1.5  ", unit: .kb, locale: enUS)
        XCTAssertEqual(limit.bytes, 1_500)
    }

    // MARK: - parse: locale separators

    func testParseCommaSeparatorUnderFrenchLocale() throws {
        let limit = try TargetSizeLimit.parse("1,5", unit: .mb, locale: frFR)
        XCTAssertEqual(limit.bytes, 1_500_000)
    }

    func testParseAsciiPointUnderFrenchLocaleParsesAsDecimalNotFifteen() throws {
        let limit = try TargetSizeLimit.parse("1.5", unit: .mb, locale: frFR)
        XCTAssertEqual(limit.bytes, 1_500_000, "1.5 must be 1.5, never 15")
    }

    func testParseCommaUnderEnglishLocaleIsMalformed() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("1,5", unit: .mb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .malformed)
        }
    }

    // MARK: - parse: errors

    func testParseEmptyString() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .empty)
        }
    }

    func testParseWhitespaceOnlyIsEmpty() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("   ", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .empty)
        }
    }

    func testParseLettersAreMalformed() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("abc", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .malformed)
        }
    }

    func testParseDoubleSeparatorIsMalformed() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("1..5", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .malformed)
        }
    }

    func testParseNegativeIsMalformed() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("-1", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .malformed)
        }
    }

    func testParseThreeFractionDigits() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("1.234", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .tooManyFractionDigits)
        }
    }

    func testParseZeroIsNonPositive() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("0", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .nonPositive)
        }
    }

    func testParseZeroFractionIsNonPositive() {
        XCTAssertThrowsError(try TargetSizeLimit.parse("0.00", unit: .kb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .nonPositive)
        }
    }

    func testParseAboveOneTerabyteOverflows() {
        // 1,000,001 MB = 1,000,001,000,000 bytes, just over the 1 TB cap.
        XCTAssertThrowsError(try TargetSizeLimit.parse("1000001", unit: .mb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .overflow)
        }
    }

    func testParseBeyondInt64NeverWrapsUnderTheCap() {
        // ~1.8e22 bytes exceeds Int64.max; a wrapped int64Value could sneak
        // under maxBytes, so the Decimal bound check must reject it first.
        XCTAssertThrowsError(try TargetSizeLimit.parse("18446744073709551616", unit: .mb, locale: enUS)) { error in
            XCTAssertEqual(error as? TargetSizeLimitParseError, .overflow)
        }
    }

    func testParseExactlyOneTerabyteSucceeds() throws {
        let limit = try TargetSizeLimit.parse("1000000", unit: .mb, locale: enUS)
        XCTAssertEqual(limit.bytes, TargetSizeLimit.maxBytes)
    }

    // MARK: - converted(to:)

    func testConvertedPreservesBytesAndChangesUnit() {
        let limit = TargetSizeLimit(bytes: 1_500_000, unit: .mb)
        let converted = limit.converted(to: .kb)
        XCTAssertEqual(converted.bytes, 1_500_000)
        XCTAssertEqual(converted.unit, .kb)
    }

    func testConvertedRoundTripKeepsBytes() {
        let limit = TargetSizeLimit(bytes: 250_000, unit: .kb)
        XCTAssertEqual(limit.converted(to: .mb).converted(to: .kb).bytes, 250_000)
    }

    // MARK: - displayValue

    func testDisplayWholeMegabyte() {
        let limit = TargetSizeLimit(bytes: 1_000_000, unit: .mb)
        XCTAssertEqual(limit.displayValue(locale: enUS), "1")
    }

    func testDisplayKilobytesForOneMillionBytes() {
        let limit = TargetSizeLimit(bytes: 1_000_000, unit: .kb)
        XCTAssertEqual(limit.displayValue(locale: enUS), "1000")
    }

    func testDisplayFractionalMegabyte() {
        let limit = TargetSizeLimit(bytes: 1_500_000, unit: .mb)
        XCTAssertEqual(limit.displayValue(locale: enUS), "1.5")
    }

    func testDisplayRoundsToTwoFractionDigits() {
        let limit = TargetSizeLimit(bytes: 1_234_567, unit: .mb)
        XCTAssertEqual(limit.displayValue(locale: enUS), "1.23")
    }

    func testDisplayUsesFrenchSeparator() {
        let limit = TargetSizeLimit(bytes: 1_500_000, unit: .mb)
        XCTAssertEqual(limit.displayValue(locale: frFR), "1,5")
    }

    func testDisplayRoundTripWithParse() throws {
        let original = TargetSizeLimit(bytes: 1_230_000, unit: .mb)
        let shown = original.displayValue(locale: enUS)
        let reparsed = try TargetSizeLimit.parse(shown, unit: .mb, locale: enUS)
        XCTAssertEqual(reparsed.bytes, 1_230_000)
    }

    func testDisplayRoundTripFrenchLocale() throws {
        let original = TargetSizeLimit(bytes: 1_500_000, unit: .mb)
        let shown = original.displayValue(locale: frFR)
        let reparsed = try TargetSizeLimit.parse(shown, unit: .mb, locale: frFR)
        XCTAssertEqual(reparsed.bytes, 1_500_000)
    }
}
