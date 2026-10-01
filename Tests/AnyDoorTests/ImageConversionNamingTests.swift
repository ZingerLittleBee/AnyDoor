import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class ImageConversionNamingTests: XCTestCase {
    func testBitmapBaseNameUsesClipboardPrefixAndTimestamp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_720_000_000) // 2024-07-03 09:46:40 UTC

        let base = ImageConversionNaming.bitmapBaseName(timestamp: date, calendar: calendar)

        XCTAssertEqual(base, "Clipboard 2024-07-03 09.46.40")
    }
}
