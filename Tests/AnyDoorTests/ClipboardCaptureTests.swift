import AppKit
import XCTest
@testable import AnyDoor

final class ClipboardCaptureTests: XCTestCase {
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorTest-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testPlainTextClassifiesAsText() throws {
        let pb = pasteboard()
        pb.setString("  hello world  ", forType: .string)
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .text(let plain, let rich, let richType) = captured else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(plain, "hello world")   // trimmed
        XCTAssertNil(rich)
        XCTAssertNil(richType)
    }

    func testRichTextKeepsRtfPayload() throws {
        let pb = pasteboard()
        let attributed = NSAttributedString(string: "styled")
        let rtf = try XCTUnwrap(attributed.rtf(from: NSRange(location: 0, length: attributed.length)))
        pb.setData(rtf, forType: .rtf)
        pb.setString("styled", forType: .string)
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .text(let plain, let rich, let richType) = captured else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(plain, "styled")
        XCTAssertEqual(rich, rtf)
        XCTAssertEqual(richType, NSPasteboard.PasteboardType.rtf.rawValue)
    }

    func testConcealedTypeIsSkipped() {
        let pb = pasteboard()
        pb.setString("s3cret", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testTransientTypeIsSkipped() {
        let pb = pasteboard()
        pb.setString("tmp", forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testEmptyOrWhitespaceTextIsSkipped() {
        let pb = pasteboard()
        pb.setString("   \n  ", forType: .string)
        XCTAssertNil(ClipboardCapture.classify(pb))
    }

    func testImageClassifiesAsImage() throws {
        let pb = pasteboard()
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 2, height: 2).fill(); image.unlockFocus()
        XCTAssertTrue(pb.writeObjects([image]))
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .image(let png) = captured else { return XCTFail("expected image") }
        XCTAssertFalse(png.isEmpty)
    }

    func testFileUrlsClassifyAsFiles() throws {
        let pb = pasteboard()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(pb.writeObjects([url as NSURL]))
        let captured = try XCTUnwrap(ClipboardCapture.classify(pb))
        guard case .files(let urls) = captured else { return XCTFail("expected files") }
        XCTAssertEqual(urls.first?.lastPathComponent, url.lastPathComponent)
    }
}
