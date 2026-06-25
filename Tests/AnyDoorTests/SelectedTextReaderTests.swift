import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

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

    func testRestoreWriteIsSuppressedFromClipboardWatcher() async throws {
        let pb = makePasteboard()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })
        let previousWatcher = ClipboardWatcher.shared
        defer { ClipboardWatcher.shared = previousWatcher }
        ClipboardWatcher.shared = watcher

        _ = await SelectedTextReader.readViaClipboard(
            pasteboard: pb,
            copy: {
                pb.clearContents()
                pb.setString("SELECTED", forType: .string)
            },
            settle: {}
        )

        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)
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
}
