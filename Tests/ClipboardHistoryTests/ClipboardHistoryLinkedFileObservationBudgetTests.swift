import AppKit
import Darwin
import Foundation
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testManyTopLevelLinkedFilesBoundNativeHandlesAndReconcileUnobservedSaves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-observation-budget-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let sourceRoot = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        var files: [URL] = []
        let board = NSPasteboard(name: .init("dev.bybee.AnyDoor.observation-budget.\(UUID())"))
        defer { board.releaseGlobally() }
        var items: [NSPasteboardItem] = []
        for index in 0..<96 {
            let url = sourceRoot.appendingPathComponent("photo-\(index).txt")
            try Data("original photo \(index)".utf8).write(to: url)
            files.append(url)
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            items.append(item)
        }
        XCTAssertTrue(board.writeObjects(items))
        let cloud = LinkedFileCloud()
        let services = ClipboardSyncServices(transport: cloud, keys: LinkedFileKeys(), pollingInterval: nil)
        let senderRoot = root.appendingPathComponent("Sender")
        let sender = makeLinkedModule(root: senderRoot, services: services, key: 0x71)
        let receiver = makeLinkedModule(root: root.appendingPathComponent("Receiver"), services: services, key: 0x72)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: board), source: .unknown) else {
            return XCTFail("Expected separate top-level file references")
        }
        let tag = try await sender.createTagDefinition(named: "Many files", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let originals = try await sender.linkedFileLocations(for: capture.entryID)
        XCTAssertEqual(originals.count, 96)

        // Observe the process's real native handles, without querying module
        // internals or changing this process's file-descriptor limit.
        var observedPaths: Set<String> = []
        let canonicalRoot = sourceRoot.resolvingSymlinksInPath().path + "/"
        for descriptor in 0..<getdtablesize() {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let canonical = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if canonical.hasPrefix(canonicalRoot) { observedPaths.insert(canonical) }
        }
        print("LINKED_OBSERVATION_ROOT_HANDLES=\(observedPaths.count)")
        XCTAssertLessThanOrEqual(observedPaths.count, 64, "Native root observation must leave a bounded descriptor budget")
        let unobserved = files.filter { !observedPaths.contains($0.resolvingSymlinksInPath().path) }
        let changed = Array((unobserved.isEmpty ? files : unobserved).suffix(3))
        let saved = Data("saved without a native root watcher".utf8)
        for url in changed { try saved.write(to: url) }
        let deadline = Date().addingTimeInterval(25)
        var receivedAll = false
        repeat {
            await receiver.retrySync()
            let locations = try await receiver.linkedFileLocations(for: capture.entryID)
            receivedAll = changed.allSatisfy { source in
                guard let original = originals.first(where: { $0.url.lastPathComponent == source.lastPathComponent }),
                      let working = locations.first(where: { $0.objectID == original.objectID }) else { return false }
                return (try? Data(contentsOf: working.url)) == saved
            }
            if receivedAll { break }
            try await Task.sleep(for: .milliseconds(300))
        } while Date() < deadline
        XCTAssertTrue(receivedAll, "Every unobserved location must progress without refreshing the source module")

        try await sender.setSyncEnabled(false)
        let uploadsBeforeOffSave = await cloud.uploadCount()
        let offSave = Data("saved while source observation is disabled".utf8)
        for url in changed { try offSave.write(to: url) }
        try await Task.sleep(for: .seconds(6))
        let uploadsAfterOffSave = await cloud.uploadCount()
        XCTAssertEqual(uploadsAfterOffSave, uploadsBeforeOffSave)
        try await sender.closeStoreForTesting()
        let reopened = makeLinkedModule(root: senderRoot, services: services, key: 0x71)
        try await reopened.setSyncEnabled(true)
        await receiver.retrySync()
        let recovered = try await receiver.materialize(.init(entryID: capture.entryID, purpose: .normalPaste))
        let recoveredFiles = recovered.items.flatMap(\.representations).compactMap { representation -> URL? in
            guard case .file(let file) = representation else { return nil }
            return file.currentURL
        }
        XCTAssertEqual(recoveredFiles.count, 96)
        XCTAssertEqual(try recoveredFiles.filter { try Data(contentsOf: $0) == offSave }.count, changed.count)
    }
}
