import AppKit
import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class ClipboardWatcherTests: XCTestCase {
    private func makeStore() throws -> ClipboardHistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ClipboardHistoryItem.self, configurations: config)
        let store = ClipboardHistoryStore(now: { Date(timeIntervalSinceReferenceDate: 100) })
        store.bootstrap(modelContainer: container)
        return store
    }

    func testPollRecordsNewTextOnce() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })

        pb.clearContents(); pb.setString("hello", forType: .string)
        await watcher.poll()
        await watcher.poll()   // no change → no second record
        await store.reload(kind: .text)
        XCTAssertEqual(store.items(for: .text).map(\.text), ["hello"])
    }

    func testPollSkipsExcludedApp() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(
            store: store,
            pasteboard: pb,
            sourceProvider: { ClipboardSource(bundleID: "com.banking.secure", appName: "Bank") },
            isExcluded: { $0 == "com.banking.secure" }
        )
        pb.clearContents(); pb.setString("secret", forType: .string)
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)
    }

    func testSelfWriteIsSuppressed() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })

        // Simulate AnyDoor writing the pasteboard during a paste, then noting it.
        pb.clearContents(); let cc = pb.setString("from-history", forType: .string) ? pb.changeCount : 0
        watcher.noteSelfWrite(changeCount: cc)
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)   // our own write was ignored
    }

    func testSelfWriteFunnelWritesAndSuppresses() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })
        ClipboardWatcher.shared = watcher
        defer { ClipboardWatcher.shared = nil }

        ClipboardWatcher.selfWrite(string: "internal", to: pb)
        XCTAssertEqual(pb.string(forType: .string), "internal")
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)   // funnel suppressed the capture
    }

    func testSelfWriteThrowingBodyStillSuppresses() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })
        ClipboardWatcher.shared = watcher
        defer { ClipboardWatcher.shared = nil }

        // A body that clears (bumping changeCount) and then fails must still
        // suppress the partial write.
        XCTAssertThrowsError(try ClipboardWatcher.selfWrite(to: pb) { p -> Void in
            p.clearContents()
            throw ClipboardHistoryError.missingText
        })
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertTrue(store.items(for: .text).isEmpty)
    }

    func testExternalWriteAfterSelfWriteIsStillRecorded() async throws {
        let store = try makeStore()
        let pb = NSPasteboard(name: NSPasteboard.Name("AnyDoorWatch-\(UUID().uuidString)"))
        let watcher = ClipboardWatcher(store: store, pasteboard: pb, sourceProvider: { nil })
        ClipboardWatcher.shared = watcher
        defer { ClipboardWatcher.shared = nil }

        ClipboardWatcher.selfWrite(string: "internal", to: pb)
        // A later "external" copy advances changeCount past the suppressed one.
        pb.clearContents(); pb.setString("external", forType: .string)
        await watcher.poll()
        await store.reload(kind: .text)
        XCTAssertEqual(store.items(for: .text).map(\.text), ["external"])
    }
}
