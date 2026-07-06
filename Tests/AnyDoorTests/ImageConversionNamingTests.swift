import XCTest
@testable import AnyDoor

final class ImageConversionNamingTests: XCTestCase {
    func testOutputURLUsesSourceBasenameAndTargetExtension() {
        let source = URL(fileURLWithPath: "/tmp/Photo.webp")

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { _ in false }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo.jpg")
        XCTAssertEqual(output.deletingLastPathComponent().path, "/tmp")
    }

    func testOutputURLSuffixesOnCollision() {
        let source = URL(fileURLWithPath: "/tmp/Photo.webp")
        let taken: Set<String> = ["Photo.jpg", "Photo 2.jpg"]

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { taken.contains($0.lastPathComponent) }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo 3.jpg")
    }

    func testOutputURLNeverOverwritesSourceWhenTargetExtensionMatches() {
        let source = URL(fileURLWithPath: "/tmp/Photo.jpg")

        let output = ImageConversionNaming.outputURL(
            forFileSource: source,
            target: .jpeg,
            exists: { $0 == source }
        )

        XCTAssertEqual(output.lastPathComponent, "Photo 2.jpg")
    }
}
