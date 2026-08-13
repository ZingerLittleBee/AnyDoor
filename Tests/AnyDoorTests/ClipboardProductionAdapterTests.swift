import AppKit
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardProductionAdapterTests: XCTestCase {
    func testExplicitProductionsWriteSemanticValuesAndAvoidPassiveDuplicates()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeStore() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        let ocr = try await fixture.adapter.produceOCR("recognized text")
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "recognized text"
        )
        XCTAssertEqual(ocr.pasteboardChangeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()

        let qr = try await fixture.adapter.produceQRCode("https://example.com")
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "https://example.com"
        )
        XCTAssertEqual(qr.pasteboardChangeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()

        let color = try await fixture.adapter.produceColor(
            hex: "#AABBCC",
            pasteboardValue: "rgb(170 187 204)"
        )
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "rgb(170 187 204)"
        )
        XCTAssertEqual(
            color.pasteboardChangeCount,
            fixture.pasteboard.changeCount
        )
        await monitor.observeForTesting()

        let (image, png) = try Self.makeImage()
        let screenshot = try await fixture.adapter.produceScreenshot(
            image: image,
            png: png,
            copyToPasteboard: true
        )
        XCTAssertEqual(
            screenshot.pasteboardChangeCount,
            fixture.pasteboard.changeCount
        )
        XCTAssertNotNil(fixture.pasteboard.data(forType: .tiff))
        await monitor.observeForTesting()

        let page = try await fixture.module.page(.init())
        XCTAssertEqual(page.entries.count, 4)
        XCTAssertEqual(page.entries.map(\.id), [
            screenshot.capture.entryID,
            color.capture.entryID,
            qr.capture.entryID,
            ocr.capture.entryID,
        ])
        XCTAssertEqual(page.entries[0].facets, [.image, .screenshot])
        XCTAssertTrue(page.entries[1].facets.contains(.color))
        XCTAssertTrue(page.entries[2].facets.contains(.qrCode))
        XCTAssertEqual(page.entries[3].previewText, "recognized text")
        XCTAssertTrue(
            page.entries.allSatisfy { $0.source == .anyDoor }
        )
    }

    func testScreenshotCanRecordWithoutChangingPasteboard() async throws {
        let fixture = try Fixture()
        defer { fixture.removeStore() }
        fixture.pasteboard.clearContents()
        XCTAssertTrue(
            fixture.pasteboard.setString("keep me", forType: .string)
        )
        let initialChangeCount = fixture.pasteboard.changeCount
        let (image, png) = try Self.makeImage()

        let outcome = try await fixture.adapter.produceScreenshot(
            image: image,
            png: png,
            copyToPasteboard: false
        )

        XCTAssertNil(outcome.pasteboardChangeCount)
        XCTAssertEqual(fixture.pasteboard.changeCount, initialChangeCount)
        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "keep me"
        )
        let page = try await fixture.module.page(.init())
        XCTAssertEqual(page.entries.map(\.id), [outcome.capture.entryID])
        XCTAssertEqual(page.entries.first?.facets, [.image, .screenshot])
    }

    func testCaptureFailureIsThrownAndSuppressedWriteIsNotPassivelyCaptured()
        async throws
    {
        let fixture = try Fixture(faults: [.databaseTransaction])
        defer { fixture.removeStore() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        do {
            _ = try await fixture.adapter.produceOCR("cannot persist")
            XCTFail("Expected explicit capture to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .storageFailure
            )
        }

        XCTAssertEqual(
            fixture.pasteboard.string(forType: .string),
            "cannot persist"
        )
        await monitor.observeForTesting()
        let page = try await fixture.module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testCopyingRecordedScreenshotSuppressesWithoutCreatingCapture()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeStore() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: fixture.module,
            pasteboard: fixture.pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)
        let (image, _) = try Self.makeImage()

        let changeCount = try fixture.adapter.copyExistingScreenshot(image)

        XCTAssertEqual(changeCount, fixture.pasteboard.changeCount)
        await monitor.observeForTesting()
        let page = try await fixture.module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    private static func makeImage() throws -> (NSImage, Data) {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 2, height: 2)).fill()
        image.unlockFocus()
        return (image, try XCTUnwrap(image.pngData()))
    }
}

@MainActor
private final class Fixture {
    let directory: URL
    let module: ClipboardHistoryModule
    let pasteboard: NSPasteboard
    let adapter: ClipboardProductionAdapter

    init(faults: Set<ClipboardHistoryFaultPoint> = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-ClipboardProduction-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        module = try ClipboardHistoryModule(
            testingDatabaseURL: directory
                .appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32),
            faultInjector: ClipboardHistoryFaultInjector(points: faults)
        )
        pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "AnyDoor-ClipboardProduction-\(UUID().uuidString)"
            )
        )
        adapter = ClipboardProductionAdapter(
            module: module,
            selfWrites: module.pasteboardSelfWrites,
            pasteboard: pasteboard
        )
    }

    func removeStore() {
        try? FileManager.default.removeItem(at: directory)
    }
}
