import ClipboardHistory
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLegacyAdapterTests: XCTestCase {
    func testAdapterReadsVersionedTransferWithoutMutatingLegacyState()
        throws
    {
        let payloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyAdapter-\(UUID().uuidString)"
            )
        try FileManager.default.createDirectory(
            at: payloadDirectory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: payloadDirectory)
        }
        let legacyPayload = payloadDirectory.appendingPathComponent(
            "owned-copy"
        )
        try Data("legacy bytes".utf8).write(to: legacyPayload)
        let configuration = ModelConfiguration(
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: ClipboardHistoryItem.self,
            configurations: configuration
        )
        let context = container.mainContext
        let olderID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let newerID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let fileManifest = try JSONEncoder().encode([
            ClipboardFileEntry(
                storedName: "owned-copy",
                originalName: "Document.txt",
                originalPath: "/Users/example/Document.txt"
            )
        ])
        context.insert(
            ClipboardHistoryItem(
                id: olderID,
                kind: .text,
                text: "plain",
                previewTitle: "Plain preview",
                createdAt: Date(timeIntervalSince1970: 100),
                richData: Data("rich".utf8),
                richType: "public.rtf",
                sourceBundleID: "com.example.source",
                sourceAppName: "Source",
                isFavorite: true,
                tagIDs: ["work", "orphan"]
            )
        )
        context.insert(
            ClipboardHistoryItem(
                id: newerID,
                kind: .file,
                previewTitle: "Document.txt",
                createdAt: Date(timeIntervalSince1970: 200),
                filesManifest: fileManifest,
                isReferenceOnly: false
            )
        )
        try context.save()

        let suiteName = "ClipboardHistoryLegacyAdapterTests-\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let tags = [
            ClipboardTag(id: "work", name: "Work"),
            ClipboardTag(id: "later", name: "Later"),
        ]
        defaults.set(
            String(
                data: try JSONEncoder().encode(tags),
                encoding: .utf8
            ),
            forKey: ClipboardTagStore.defaultsKey
        )
        defaults.set(
            String(
                data: try JSONEncoder().encode([
                    "all", "tag:later", "favorites", "tag:work",
                ]),
                encoding: .utf8
            ),
            forKey: ClipboardCategoryOrder.defaultsKey
        )
        defaults.set(
            ClipboardRetention.sevenDays.rawValue,
            forKey: ClipboardPreferences.retentionKey
        )
        let request = try ClipboardHistoryLegacyAdapter
            .makeMigrationRequest(
                modelContext: context,
                defaults: defaults,
                payloadDirectory: payloadDirectory
            )

        XCTAssertEqual(
            request.transfer.version,
            ClipboardHistoryLegacyTransfer.currentVersion
        )
        XCTAssertEqual(
            request.transfer.entries.map(\.id),
            [newerID, olderID]
        )
        XCTAssertEqual(
            request.transfer.entries.map(\.source.provenance),
            [.legacy, .legacy]
        )
        XCTAssertEqual(
            request.transfer.entries[0].files,
            [
                ClipboardHistoryLegacyFileMember(
                    storedName: "owned-copy",
                    originalName: "Document.txt",
                    originalPath: "/Users/example/Document.txt"
                )
            ]
        )
        XCTAssertEqual(
            request.transfer.entries[1].richData,
            Data("rich".utf8)
        )
        XCTAssertEqual(request.transfer.entries[1].tagIDs, ["work", "orphan"])
        XCTAssertEqual(
            request.transfer.tags,
            [
                ClipboardHistoryLegacyTag(id: "work", name: "Work"),
                ClipboardHistoryLegacyTag(id: "later", name: "Later"),
            ]
        )
        XCTAssertEqual(
            request.transfer.categoryOrder,
            ["all", "tag:later", "favorites", "tag:work"]
        )
        XCTAssertEqual(request.transfer.retentionPeriod, .sevenDays)
        XCTAssertEqual(request.payloadDirectory, payloadDirectory)

        let persisted = try context.fetch(
            FetchDescriptor<ClipboardHistoryItem>()
        )
        XCTAssertEqual(Set(persisted.map(\.id)), [olderID, newerID])
        XCTAssertEqual(
            try Data(contentsOf: legacyPayload),
            Data("legacy bytes".utf8)
        )
    }
}
