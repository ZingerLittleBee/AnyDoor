import AppKit
import XCTest
@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class SelectedTextReaderTests: XCTestCase {
    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorSel-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testReadsCopiedSelectionAndRestoresPriorContents() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        XCTAssertEqual(text, "SELECTED")
        // Prior pasteboard contents must be restored after the read.
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testRestoresRichPriorContents() async {
        let pb = makePasteboard()
        let rtf = Data("{\\rtf1\\ansi ORIGINAL}".utf8)
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)
        pb.setData(rtf, forType: .rtf)

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        XCTAssertEqual(text, "SELECTED")
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
        XCTAssertEqual(pb.data(forType: .rtf), rtf)
    }

    func testRestoreWriteIsSuppressedFromClipboardMonitor() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let (module, storeRoot) = try makeModule()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let funnel = module.pasteboardSelfWrites
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pb,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        _ = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            selfWrites: funnel,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        await monitor.observeForTesting()
        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testIntermediateSelectionWriteIsSuppressedFromClipboardMonitor()
        async throws
    {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let (module, storeRoot) = try makeModule()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let funnel = module.pasteboardSelfWrites
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pb,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)

        _ = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            selfWrites: funnel,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {
                await monitor.observeForTesting()
            }
        )

        await monitor.observeForTesting()
        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
    }

    func testReturnsNilWhenSelectionUnchangedAndRestores() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        // copy() does nothing — simulates "no selection / nothing copied".
        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {},
            settle: {}
        )

        XCTAssertNil(text)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testReturnsNilForWhitespaceOnlySelection() async {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("   \n\t", forType: .string)
            },
            settle: {}
        )

        XCTAssertNil(text)
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testRestoresEmptyPriorPasteboard() async {
        let pb = makePasteboard()
        pb.clearContents() // no prior string

        let text = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        XCTAssertEqual(text, "SELECTED")
        // Nothing to restore: the pasteboard string is cleared back to nil.
        XCTAssertNil(pb.string(forType: .string))
    }

    private func makeModule() throws
        -> (ClipboardHistoryModule, URL)
    {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-SelectedText-\(UUID().uuidString)",
                isDirectory: true
            )
        return (
            try ClipboardHistoryModule(
                testingDatabaseURL: storeRoot
                    .appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x6B, count: 32)
            ),
            storeRoot
        )
    }
}
