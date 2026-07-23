import Foundation
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class FinderSelectionReaderTests: XCTestCase {
    func testParseReturnsImageURLsForMultiLinePaths() {
        let output = """
        /Users/me/Pictures/a.png
        /Users/me/Pictures/b.jpg
        /Users/me/Pictures/c.heic
        """

        let urls = FinderSelectionReader.parse(output)

        XCTAssertEqual(urls.map(\.path), [
            "/Users/me/Pictures/a.png",
            "/Users/me/Pictures/b.jpg",
            "/Users/me/Pictures/c.heic",
        ])
    }

    func testParseReturnsEmptyForEmptyOutput() {
        XCTAssertTrue(FinderSelectionReader.parse("").isEmpty)
        XCTAssertTrue(FinderSelectionReader.parse("   \n  \n").isEmpty)
    }

    func testParseFiltersOutNonImageEntries() {
        let output = """
        /Users/me/Pictures/photo.png
        /Users/me/Documents/notes.txt
        /Users/me/Projects/SomeFolder
        /Users/me/Pictures/diagram.webp
        /Users/me/Movies/clip.mov
        """

        let urls = FinderSelectionReader.parse(output)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["photo.png", "diagram.webp"])
    }

    func testParseTrimsWhitespaceAndSkipsBlankLines() {
        let output = "  /Users/me/Pictures/a.png  \n\n\t/Users/me/Pictures/b.JPG\n"

        let urls = FinderSelectionReader.parse(output)

        XCTAssertEqual(urls.map(\.lastPathComponent), ["a.png", "b.JPG"])
    }

    func testParseIsCaseInsensitiveForExtensions() {
        let output = "/Users/me/Pictures/A.PNG\n/Users/me/Pictures/B.Heic"

        let urls = FinderSelectionReader.parse(output)

        XCTAssertEqual(urls.count, 2)
    }
}
