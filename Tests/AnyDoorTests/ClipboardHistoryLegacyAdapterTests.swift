import ClipboardHistory
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLegacyAdapterTests: XCTestCase {
    func testCutoverSnapshotPreservesLegacyRowsWhileProductionSchemaDropsModel()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyCutover-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let storeURL = root.appendingPathComponent("AnyDoor.store")
        let legacySchema = Schema([
            KeyBinding.self,
            ClipboardHistoryItem.self,
        ])
        do {
            let container = try ModelContainer(
                for: legacySchema,
                configurations: ModelConfiguration(url: storeURL)
            )
            container.mainContext.insert(
                KeyBinding(
                    keyCode: 122,
                    modifierFlags: 0,
                    appBundleID: "com.apple.finder",
                    appName: "Finder",
                    appPath:
                        "/System/Library/CoreServices/Finder.app"
                )
            )
            container.mainContext.insert(
                ClipboardHistoryItem(
                    kind: .text,
                    text: "unique readable copy",
                    previewTitle: "unique readable copy"
                )
            )
            try container.mainContext.save()
        }

        let legacyPayloadDirectory = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyPayloadDirectory,
            withIntermediateDirectories: true
        )
        let legacyPayload = legacyPayloadDirectory
            .appendingPathComponent("owned-copy")
        try Data("legacy payload".utf8).write(to: legacyPayload)
        let source = try ClipboardHistoryLegacySource(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL,
            legacySchema: legacySchema,
            payloadDirectory: legacyPayloadDirectory
        )

        let productionContainer = try ModelContainer(
            for: Schema([KeyBinding.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<KeyBinding>()
            ).map(\.appBundleID),
            ["com.apple.finder"]
        )
        let request = try source.makeMigrationRequest(
            defaults: makeDefaults()
        )
        XCTAssertEqual(
            request.transfer.entries.map(\.text),
            ["unique readable copy"]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyPayload.path)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: request.payloadDirectory
                    .appendingPathComponent("owned-copy")
            ),
            Data("legacy payload".utf8)
        )

        let snapshotDirectory =
            ClipboardHistoryLegacySource.snapshotDirectory(in: root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: snapshotDirectory.path
            )
        )
        try source.finishMigration()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshotDirectory.path
            )
        )
    }

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
            forKey: ClipboardHistoryPortableKeys.customTags
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

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ClipboardHistoryLegacySourceTests-\(UUID())"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
