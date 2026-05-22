import XCTest
import AppKit
@testable import AnyDoor

/// `@MainActor` because the helper draws with AppKit (`NSImage.lockFocus`), which
/// must run on the main thread.
@MainActor
final class RegionCaptureTests: XCTestCase {

    /// Renders `text` as black text on white and writes it to `url` as a PNG.
    private func writeTextPNG(_ text: String, to url: URL) throws {
        let size = NSSize(width: 700, height: 180)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        text.draw(at: NSPoint(x: 40, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64),
            .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("failed to encode the test PNG")
        }
        try png.write(to: url)
    }

    /// Reproduces the OCRProvider flow: decode a screencapture-style PNG, then delete
    /// the file (as `RegionCapture.captureRegion` does via `defer`) before recognition.
    /// The decoded CGImage must not lazily depend on the now-deleted file.
    func testDecodedImageSurvivesSourceFileDeletion() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("anydoor-ocr-test-\(UUID().uuidString).png")
        try writeTextPNG("Persisted", to: url)

        let decoded = try XCTUnwrap(RegionCapture.decodeImage(at: url))
        try FileManager.default.removeItem(at: url)

        let lines = try await TextRecognizer.recognize(decoded)
        XCTAssertTrue(lines.joined().contains("Persisted"),
                      "recognition must work after the source file is deleted; got: \(lines)")
    }
}
