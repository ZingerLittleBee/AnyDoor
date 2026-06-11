import XCTest
import AppKit
@testable import AnyDoor

/// `@MainActor` because the helper draws with AppKit (`NSImage.lockFocus`), which
/// must run on the main thread.
@MainActor
final class TextRecognizerTests: XCTestCase {

    /// Renders each string as a separate line of black system-font text on white,
    /// first element at the top. Returns the rasterized CGImage.
    private func renderImage(lines: [String]) throws -> CGImage {
        let width: CGFloat = 800
        let lineHeight: CGFloat = 100
        let height = max(lineHeight, lineHeight * CGFloat(lines.count)) + 40
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56),
            .foregroundColor: NSColor.black,
        ]
        // AppKit's origin is bottom-left; draw the first line near the top.
        for (index, line) in lines.enumerated() {
            let y = height - 40 - lineHeight * CGFloat(index) - 60
            line.draw(at: NSPoint(x: 40, y: y), withAttributes: attrs)
        }
        image.unlockFocus()

        var rect = NSRect(origin: .zero, size: size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw XCTSkip("failed to rasterize the test image")
        }
        return cgImage
    }

    func testDefaultConfigurationCoversTraditionalChinese() {
        let configuration = TextRecognizer.defaultConfiguration
        XCTAssertTrue(configuration.automaticallyDetectsLanguage)
        XCTAssertTrue(configuration.recognitionLanguages.contains("zh-Hant"))
    }

    func testRecognizesEnglishText() async throws {
        let image = try renderImage(lines: ["Hello World"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined(separator: "\n")
        XCTAssertTrue(joined.contains("Hello"), "got: \(joined)")
        XCTAssertTrue(joined.contains("World"), "got: \(joined)")
    }

    func testRecognizesChineseText() async throws {
        let image = try renderImage(lines: ["你好世界"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined()
        XCTAssertTrue(joined.contains("你好"), "got: \(joined)")
    }

    func testReturnsLinesTopToBottom() async throws {
        let image = try renderImage(lines: ["Sunrise", "Mountain"])
        let result = try await TextRecognizer.recognize(image)
        let joined = result.joined(separator: "\n")
        guard let sunrise = joined.range(of: "Sunrise"),
              let mountain = joined.range(of: "Mountain") else {
            XCTFail("both lines should be recognized; got: \(joined)")
            return
        }
        XCTAssertLessThan(sunrise.lowerBound, mountain.lowerBound,
                          "Sunrise (top) should precede Mountain (bottom); got: \(joined)")
    }

    func testBlankImageReturnsEmpty() async throws {
        let image = try renderImage(lines: [])
        let result = try await TextRecognizer.recognize(image)
        XCTAssertEqual(result, [])
    }
}
