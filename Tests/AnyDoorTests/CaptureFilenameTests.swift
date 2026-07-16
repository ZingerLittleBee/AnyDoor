import XCTest
import PluginInterface
@testable import AnyDoor

final class CaptureFilenameTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return utcCalendar().date(from: c)!
    }

    func testExpandsTokens() {
        let name = CaptureFilename.make(
            template: "Screenshot YYYY-MM-DD at HH.mm.ss",
            date: date(2026, 6, 14, 9, 5, 3),
            calendar: utcCalendar()
        )
        XCTAssertEqual(name, "Screenshot 2026-06-14 at 09.05.03")
    }

    func testStripsPathSeparators() {
        let name = CaptureFilename.make(
            template: "a/b:c",
            date: date(2026, 1, 1, 0, 0, 0),
            calendar: utcCalendar()
        )
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testResolveReturnsBaseWhenFree() {
        let resolved = CaptureFilename.resolve(base: "Shot", ext: "png") { _ in false }
        XCTAssertEqual(resolved, "Shot.png")
    }

    func testResolveSuffixesOnCollision() {
        let taken: Set<String> = ["Shot.png", "Shot 2.png"]
        let resolved = CaptureFilename.resolve(base: "Shot", ext: "png") { taken.contains($0) }
        XCTAssertEqual(resolved, "Shot 3.png")
    }
}
