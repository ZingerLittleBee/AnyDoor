import XCTest
@testable import AnyDoor

final class CurrencyConversionTests: XCTestCase {
    private static let table = RateTable(
        base: "USD",
        rates: ["EUR": 0.925, "GBP": 0.79, "CNY": 7.1, "JPY": 150],
        date: "2026-06-13"
    )

    private func first(_ query: String) -> ConversionResult? {
        CurrencyConversion.detect(query, rates: Self.table).first
    }

    func testUSDToEUR() {
        let r = first("100 usd to eur")
        XCTAssertEqual(r?.display, "92.50 EUR")
        XCTAssertEqual(r?.copyText, "92.50")
        XCTAssertEqual(r?.kind, .currency)
    }

    func testEURToUSDRoundsToTwoDecimals() {
        XCTAssertEqual(first("100 eur to usd")?.display, "108.11 USD")
    }

    func testCrossPairThroughBase() {
        // 100 EUR -> CNY = 100 * 7.1 / 0.925
        XCTAssertEqual(first("100 eur in cny")?.display, "767.57 CNY")
    }

    func testGBPToUSD() {
        XCTAssertEqual(first("50 gbp to usd")?.display, "63.29 USD")
    }

    func testDollarSymbolPrefix() {
        XCTAssertEqual(first("$100 to eur")?.display, "92.50 EUR")
    }

    func testEuroSymbolPrefix() {
        XCTAssertEqual(first("€50 to usd")?.display, "54.05 USD")
    }

    func testCommaGroupedAmount() {
        XCTAssertEqual(first("1,000 usd to eur")?.display, "925.00 EUR")
    }

    func testDetailCarriesRateDate() {
        XCTAssertEqual(first("100 usd to eur")?.detail, "2026-06-13")
    }

    // MARK: - Guards

    func testNilRatesProducesNoRow() {
        XCTAssertTrue(CurrencyConversion.detect("100 usd to eur", rates: nil).isEmpty)
    }

    func testUnknownCodeProducesNoRow() {
        XCTAssertTrue(CurrencyConversion.detect("100 xyz to usd", rates: Self.table).isEmpty)
        XCTAssertTrue(CurrencyConversion.detect("100 usd to xyz", rates: Self.table).isEmpty)
    }

    func testUnitsAreNotCurrency() {
        XCTAssertTrue(CurrencyConversion.detect("3 ft to m", rates: Self.table).isEmpty)
    }

    func testMissingAmountProducesNoRow() {
        XCTAssertTrue(CurrencyConversion.detect("usd to eur", rates: Self.table).isEmpty)
    }

    // MARK: - Hardening (review findings)

    func testCommaDecimalInputIsRejected() {
        // "1,5" is comma-decimal in some locales; the US-grouping parser must not
        // silently read it as 15. Decline rather than guess.
        XCTAssertTrue(CurrencyConversion.detect("1,5 usd to eur", rates: Self.table).isEmpty)
    }

    func testInvalidGroupingIsRejected() {
        XCTAssertTrue(CurrencyConversion.detect("1,00,000 usd to eur", rates: Self.table).isEmpty)
    }

    func testZeroRateProducesNoRow() {
        let zero = RateTable(base: "USD", rates: ["EUR": 0], date: "2026-06-13")
        // Source rate 0 would divide to Infinity; target rate 0 is nonsense too.
        XCTAssertTrue(CurrencyConversion.detect("100 eur to usd", rates: zero).isEmpty)
        XCTAssertTrue(CurrencyConversion.detect("100 usd to eur", rates: zero).isEmpty)
    }
}
