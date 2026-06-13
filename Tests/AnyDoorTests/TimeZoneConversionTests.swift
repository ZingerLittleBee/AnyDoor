import XCTest
@testable import AnyDoor

final class TimeZoneConversionTests: XCTestCase {
    private static let utc = TimeZone(identifier: "UTC")!

    /// Fixed reference instant: 2026-06-14 12:00:00 UTC (June → BST/EDT in effect).
    private static let now: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 14; c.hour = 12; c.minute = 0; c.second = 0
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal.date(from: c)!
    }()

    private func first(_ query: String) -> ConversionResult? {
        TimeZoneConversion.detect(query, now: Self.now, localZone: Self.utc).first
    }

    // MARK: - Single-place form (time in local, shown in place)

    func testLocalTimeShownInTokyoCrossesMidnight() {
        // 3pm UTC → Tokyo (UTC+9) = 00:00 next day.
        let r = first("3pm tokyo")
        XCTAssertEqual(r?.kind, .timeZone)
        XCTAssertTrue(r?.display.hasPrefix("12:00 AM") ?? false, "got \(r?.display ?? "nil")")
        XCTAssertTrue(r?.display.contains("+1d") ?? false, "got \(r?.display ?? "nil")")
        XCTAssertEqual(r?.copyText, "12:00 AM")
    }

    func testPlaceTimeKeywordShowsCurrentTimeThere() {
        // now is 12:00 UTC → Tokyo 21:00 = 9:00 PM, same day.
        let r = first("tokyo time")
        XCTAssertTrue(r?.display.hasPrefix("9:00 PM") ?? false, "got \(r?.display ?? "nil")")
        XCTAssertFalse(r?.display.contains("1d") ?? true)
    }

    // MARK: - Two-place form (time in A, shown in B)

    func testLondonToTokyo() {
        // 9am London (BST, UTC+1) = 08:00 UTC → Tokyo 17:00 = 5:00 PM, same day.
        let r = first("9am london to tokyo")
        XCTAssertTrue(r?.display.hasPrefix("5:00 PM") ?? false, "got \(r?.display ?? "nil")")
        XCTAssertEqual(r?.detail, "London → Tokyo")
    }

    func testNoonUTCToNewYork() {
        // noon UTC → New York (EDT, UTC-4) = 08:00 = 8:00 AM.
        let r = first("noon utc to new york")
        XCTAssertTrue(r?.display.hasPrefix("8:00 AM") ?? false, "got \(r?.display ?? "nil")")
    }

    func testTwentyFourHourClockParsing() {
        // 15:00 UTC → New York (EDT) = 11:00 = 11:00 AM.
        let r = first("15:00 utc to new york")
        XCTAssertTrue(r?.display.hasPrefix("11:00 AM") ?? false, "got \(r?.display ?? "nil")")
    }

    func testMidnightTokyoToUTCGoesBackADay() {
        // midnight Tokyo (00:00 JST Jun 14) = 15:00 UTC Jun 13 = 3:00 PM (−1 day).
        let r = first("midnight tokyo to utc")
        XCTAssertTrue(r?.display.hasPrefix("3:00 PM") ?? false, "got \(r?.display ?? "nil")")
        XCTAssertTrue(r?.display.contains("-1d") ?? false, "got \(r?.display ?? "nil")")
    }

    func testGMTOffsetAbbreviation() {
        XCTAssertTrue(first("3pm tokyo")?.display.contains("GMT+9") ?? false, "got \(first("3pm tokyo")?.display ?? "nil")")
    }

    // MARK: - Guards

    func testBareCityWithoutTimeKeywordProducesNoRow() {
        XCTAssertTrue(TimeZoneConversion.detect("tokyo", now: Self.now, localZone: Self.utc).isEmpty)
    }

    func testPlainTextProducesNoRow() {
        XCTAssertTrue(TimeZoneConversion.detect("hello world", now: Self.now, localZone: Self.utc).isEmpty)
    }

    func testTimeWithoutPlaceProducesNoRow() {
        XCTAssertTrue(TimeZoneConversion.detect("3pm", now: Self.now, localZone: Self.utc).isEmpty)
    }

    func testUnknownPlaceProducesNoRow() {
        XCTAssertTrue(TimeZoneConversion.detect("3pm atlantis", now: Self.now, localZone: Self.utc).isEmpty)
    }
}
