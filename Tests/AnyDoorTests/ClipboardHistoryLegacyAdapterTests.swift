import ClipboardHistoryTestSupport
@testable import ClipboardHistory
import Foundation
import SwiftData
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLegacyAdapterTests: XCTestCase {
    func testSnapshotRecursiveDeletionFailureRemainsVisibleAndRetryable()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyDeleteFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        let snapshot = ClipboardHistoryLegacySource.snapshotDirectory(
            in: root
        )
        let nested = snapshot.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        let protectedFile = nested.appendingPathComponent("payload")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try Data("protected".utf8).write(to: protectedFile)
        try FileManager.default.setAttributes(
            [.immutable: true],
            ofItemAtPath: protectedFile.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: protectedFile.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertThrowsError(
            try ClipboardHistoryLegacySource.finishMigration(in: root)
        )
        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .snapshotDeletionPending
        )
        XCTAssertThrowsError(
            try ClipboardHistoryLegacySource.retrySnapshotDeletion(
                in: root
            )
        )

        try FileManager.default.setAttributes(
            [.immutable: false],
            ofItemAtPath: protectedFile.path
        )
        try ClipboardHistoryLegacySource.retrySnapshotDeletion(in: root)
        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .completed
        )
    }

    func testCutoverMarkerPersistenceFailureRetainsReadableSnapshot()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyMarkerFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
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
                ClipboardHistoryItem(
                    kind: .text,
                    text: "must remain readable",
                    previewTitle: "must remain readable"
                )
            )
            try container.mainContext.save()
        }
        let payloadDirectory = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )
        do {
            _ = try ClipboardHistoryLegacySource.openForMigration(
                applicationSupportDirectory: root,
                productionStoreURL: storeURL,
                payloadDirectory: payloadDirectory
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o500],
                ofItemAtPath: root.path
            )
            XCTAssertThrowsError(
                try ClipboardHistoryLegacySource.finishMigration(in: root)
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
        }

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    ClipboardHistoryLegacySource
                    .snapshotDirectory(in: root).path
            )
        )
        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .incomplete
        )
        let recovered = try ClipboardHistoryLegacySource.openForMigration(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL,
            payloadDirectory: payloadDirectory
        )
        XCTAssertEqual(
            try recovered.makeMigrationRequest(
                defaults: makeDefaults()
            ).transfer.entries.map(\.text),
            ["must remain readable"]
        )
    }

    func testPublishedMigrationRecoveryNeverReopensLegacySchema()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyPublishedRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        removeClipboardHistoryDirectoryAfterTest(root)
        let storeURL = root.appendingPathComponent("AnyDoor.store")
        let productionTypes: [any PersistentModel.Type] = [
            KeyBinding.self,
            BuiltinPreference.self,
            TranslationRecord.self,
            Quicklink.self,
        ] + NativePluginCatalog.modelSchemaTypes
        let legacySchema = Schema(
            productionTypes + [ClipboardHistoryItem.self]
        )
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
                BuiltinPreference(
                    itemKey: "clipboardWall",
                    isVisible: false
                )
            )
            container.mainContext.insert(
                TranslationRecord(
                    sourceText: "source",
                    translatedText: "translated",
                    sourceLangCode: "en",
                    targetLangCode: "zh-Hans",
                    serviceID: "fixture",
                    serviceName: "Fixture"
                )
            )
            container.mainContext.insert(
                Quicklink(
                    name: "Fixture",
                    link: "https://example.com"
                )
            )
            container.mainContext.insert(
                ClipboardHistoryItem(
                    kind: .text,
                    text: "survives publication crash",
                    previewTitle: "survives publication crash"
                )
            )
            try container.mainContext.save()
        }
        let payloadDirectory = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )
        let request: ClipboardHistoryLegacyMigrationRequest = try {
            let firstLaunch = try ClipboardHistoryLegacySource
                .openForMigration(
                    applicationSupportDirectory: root,
                    productionStoreURL: storeURL,
                    payloadDirectory: payloadDirectory
                )
            return try firstLaunch.makeMigrationRequest(
                defaults: makeDefaults()
            )
        }()
        let databaseURL = root
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        let databaseKey = Data(repeating: 17, count: 32)
        let publishingModule = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: databaseURL,
                databaseKey: databaseKey,
                faultInjector: ClipboardHistoryFaultInjector(
                    points: [.legacyMigrationAfterPublication]
                )
            )
        )
        do {
            _ = try await publishingModule.migrateLegacy(request)
            XCTFail("Expected the post-publication crash boundary")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .legacyMigrationFailed
            )
        }
        try await publishingModule.closeStoreForTesting()
        let module = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: databaseURL,
                databaseKey: databaseKey
            )
        )

        let productionContainer = try ModelContainer(
            for: Schema(productionTypes),
            configurations: ModelConfiguration(url: storeURL)
        )
        let snapshotStoreURL =
            ClipboardHistoryLegacySource.snapshotDirectory(in: root)
            .appendingPathComponent("AnyDoorLegacy.store")
        try Data("not a SwiftData store".utf8).write(
            to: snapshotStoreURL,
            options: .atomic
        )
        let defaults = try makeDefaults()
        var migrationRequestCount = 0
        let lifecycle = ClipboardHistoryLifecycle(
            module: module,
            defaults: defaults,
            legacyCleanupState: {
                ClipboardHistoryLegacySource.cleanupState(in: root)
            },
            legacyPayloadDirectory: {
                ClipboardHistoryLegacySource.snapshotPayloadDirectory(
                    in: root
                )
            },
            migrationRequest: {
                migrationRequestCount += 1
                let source =
                    try ClipboardHistoryLegacySource.openForMigration(
                        applicationSupportDirectory: root,
                        productionStoreURL: storeURL,
                            payloadDirectory: payloadDirectory
                    )
                return try source.makeMigrationRequest(
                    defaults: defaults
                )
            },
            finishMigration: {
                try ClipboardHistoryLegacySource.finishMigration(in: root)
            },
            retrySnapshotDeletion: {
                try ClipboardHistoryLegacySource.retrySnapshotDeletion(
                    in: root
                )
            }
        )

        addTeardownBlock {
            await lifecycle.awaitCurrentOperationForTesting()
            await lifecycle.stop()
        }
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(migrationRequestCount, 0)
        let recoveredPage = try await module.page(
            ClipboardHistoryQuery()
        )
        XCTAssertEqual(
            recoveredPage.entries.map(\.previewText),
            ["survives publication crash"]
        )
        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .completed
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    ClipboardHistoryLegacySource.snapshotDirectory(
                        in: root
                    ).path
            )
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<KeyBinding>()
            ).map(\.appBundleID),
            ["com.apple.finder"]
        )
    }

    func testCompletedCutoverSkipsSecondSnapshotAndPreservesUnrelatedRows()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacySecondLaunch-\(UUID().uuidString)",
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
        let productionTypes: [any PersistentModel.Type] = [
            KeyBinding.self,
            BuiltinPreference.self,
            TranslationRecord.self,
            Quicklink.self,
        ] + NativePluginCatalog.modelSchemaTypes
        let legacySchema = Schema(
            productionTypes + [ClipboardHistoryItem.self]
        )
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
                BuiltinPreference(
                    itemKey: "clipboardWall",
                    isVisible: false
                )
            )
            container.mainContext.insert(
                TranslationRecord(
                    sourceText: "source",
                    translatedText: "translated",
                    sourceLangCode: "en",
                    targetLangCode: "zh-Hans",
                    serviceID: "fixture",
                    serviceName: "Fixture"
                )
            )
            container.mainContext.insert(
                Quicklink(
                    name: "Fixture",
                    link: "https://example.com"
                )
            )
            container.mainContext.insert(
                ClipboardHistoryItem(
                    kind: .text,
                    text: "migrate exactly once",
                    previewTitle: "migrate exactly once"
                )
            )
            try container.mainContext.save()
        }
        let payloadDirectory = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )

        let firstLaunch = try ClipboardHistoryLegacySource.openForMigration(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL,
            payloadDirectory: payloadDirectory
        )
        XCTAssertEqual(
            try firstLaunch.makeMigrationRequest(
                defaults: makeDefaults()
            ).transfer.entries.map(\.text),
            ["migrate exactly once"]
        )

        let productionContainer = try ModelContainer(
            for: Schema(productionTypes),
            configurations: ModelConfiguration(url: storeURL)
        )
        try ClipboardHistoryLegacySource.finishMigration(in: root)

        try ClipboardHistoryLegacySource.prepareSnapshotIfNeeded(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL
        )

        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .completed
        )
        XCTAssertThrowsError(
            try ClipboardHistoryLegacySource.openForMigration(
                applicationSupportDirectory: root,
                productionStoreURL: storeURL,
                payloadDirectory: payloadDirectory
            )
        ) { error in
            guard
                case .cutoverAlreadyCompleted? =
                    error as? ClipboardHistoryLegacySourceError
            else {
                return XCTFail("Expected a completed cutover, got \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    ClipboardHistoryLegacySource
                    .snapshotDirectory(in: root).path
            )
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<KeyBinding>()
            ).map(\.appBundleID),
            ["com.apple.finder"]
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<BuiltinPreference>()
            ).map(\.itemKey),
            ["clipboardWall"]
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<TranslationRecord>()
            ).map(\.translatedText),
            ["translated"]
        )
        XCTAssertEqual(
            try productionContainer.mainContext.fetch(
                FetchDescriptor<Quicklink>()
            ).map(\.link),
            ["https://example.com"]
        )
    }

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
        try ClipboardHistoryLegacySource.prepareSnapshotIfNeeded(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL
        )

        let productionContainer = try ModelContainer(
            for: Schema([KeyBinding.self]),
            configurations: ModelConfiguration(url: storeURL)
        )
        let source = try ClipboardHistoryLegacySource.openForMigration(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL,
            payloadDirectory: legacyPayloadDirectory
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
        try ClipboardHistoryLegacySource.finishMigration(in: root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: snapshotDirectory.path
            )
        )
    }

    /// v1 copied a symbolic link as the link itself, so the pre-v2 folder can
    /// hold links, and entries that are not regular files at all. The snapshot
    /// takes each one as it is, never replaces an entry it already holds, and
    /// deleting the snapshot removes the links, never what they point at.
    func testSnapshotCarriesSymbolicLinksWithoutFollowingThem() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "AnyDoor-LegacyLinks-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: root)
        }
        // Opening the snapshot copies the store file but never reads it here.
        let storeURL = root.appendingPathComponent("AnyDoor.store")
        try Data("legacy store".utf8).write(to: storeURL)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideFile = outside.appendingPathComponent("target.txt")
        let outsideFolder = outside.appendingPathComponent(
            "folder",
            isDirectory: true
        )
        let fileInOutsideFolder = outsideFolder.appendingPathComponent(
            "inner.txt"
        )
        try fileManager.createDirectory(
            at: outsideFolder,
            withIntermediateDirectories: true
        )
        try Data("outside".utf8).write(to: outsideFile)
        try Data("inside".utf8).write(to: fileInOutsideFolder)
        let legacyFolder = root.appendingPathComponent(
            "ClipboardHistory",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: legacyFolder.appendingPathComponent(
                "folder-copy",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try Data("legacy payload".utf8).write(
            to: legacyFolder.appendingPathComponent("owned-copy")
        )
        try fileManager.createSymbolicLink(
            at: legacyFolder.appendingPathComponent("file-link"),
            withDestinationURL: outsideFile
        )
        try fileManager.createSymbolicLink(
            at: legacyFolder.appendingPathComponent("folder-link"),
            withDestinationURL: outsideFolder
        )
        try fileManager.createSymbolicLink(
            atPath: legacyFolder.appendingPathComponent("dangling-link").path,
            withDestinationPath: "missing"
        )
        try ClipboardHistoryLegacySource.prepareSnapshotIfNeeded(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL
        )

        _ = try ClipboardHistoryLegacySource.openForMigration(
            applicationSupportDirectory: root,
            productionStoreURL: storeURL,
            payloadDirectory: legacyFolder
        )

        let snapshotPayloads = ClipboardHistoryLegacySource
            .snapshotPayloadDirectory(in: root)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(atPath: legacyFolder.path),
            []
        )
        XCTAssertEqual(
            Set(
                try fileManager.contentsOfDirectory(
                    atPath: snapshotPayloads.path
                )
            ),
            [
                "owned-copy", "folder-copy", "file-link", "folder-link",
                "dangling-link",
            ]
        )
        for (name, destination) in [
            ("file-link", outsideFile.path),
            ("folder-link", outsideFolder.path),
            ("dangling-link", "missing"),
        ] {
            XCTAssertEqual(
                try fileManager.destinationOfSymbolicLink(
                    atPath: snapshotPayloads.appendingPathComponent(name).path
                ),
                destination
            )
        }

        // A link whose target is gone still holds its name in the snapshot.
        let collision = legacyFolder.appendingPathComponent("dangling-link")
        try Data("newer".utf8).write(to: collision)
        XCTAssertThrowsError(
            try ClipboardHistoryLegacySource.openForMigration(
                applicationSupportDirectory: root,
                productionStoreURL: storeURL,
                payloadDirectory: legacyFolder
            )
        ) { error in
            guard
                case .incompleteSnapshot? =
                    error as? ClipboardHistoryLegacySourceError
            else {
                return XCTFail("Expected an incomplete snapshot, got \(error)")
            }
        }
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(
                atPath: snapshotPayloads.appendingPathComponent(
                    "dangling-link"
                ).path
            ),
            "missing"
        )
        XCTAssertEqual(try Data(contentsOf: collision), Data("newer".utf8))
        try fileManager.removeItem(at: collision)

        try ClipboardHistoryLegacySource.finishMigration(in: root)
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: ClipboardHistoryLegacySource.snapshotDirectory(
                    in: root
                ).path
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideFile), Data("outside".utf8))
        XCTAssertEqual(
            try Data(contentsOf: fileInOutsideFolder),
            Data("inside".utf8)
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
        let storeURL = try makeLegacyStoreURL()
        let container = try ModelContainer(
            for: ClipboardHistoryItem.self,
            configurations: ModelConfiguration(url: storeURL)
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

        let defaults = makeTemporaryDefaults()
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
                storeURL: storeURL,
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

    /// `recency_order` is assigned downstream straight from the transfer's
    /// sequence, so newest-first has to hold at a realistic row count, not
    /// just for the two-row fixtures above. This pins the contract against any
    /// future change to how the snapshot is read.
    func testTransferPreservesNewestFirstOrderAtScale() throws {
        let storeURL = try makeLegacyStoreURL()
        let container = try ModelContainer(
            for: ClipboardHistoryItem.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = container.mainContext
        let rowCount = 500
        var expected: [UUID] = []
        for index in 0..<rowCount {
            let id = UUID()
            expected.append(id)
            context.insert(
                ClipboardHistoryItem(
                    id: id,
                    kind: .text,
                    text: "row \(index)",
                    previewTitle: "Row \(index)",
                    // Strictly decreasing, so newest-first is unambiguous.
                    createdAt: Date(
                        timeIntervalSince1970: TimeInterval(rowCount - index)
                    )
                )
            )
        }
        try context.save()

        let request = try ClipboardHistoryLegacyAdapter.makeMigrationRequest(
            storeURL: storeURL,
            defaults: try makeDefaults(),
            payloadDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertEqual(request.transfer.entries.count, rowCount)
        XCTAssertEqual(request.transfer.entries.map(\.id), expected)
    }

    /// A single row the current schema cannot describe must not cost the user
    /// their whole history: a thrown transfer would fail migration on every
    /// retry, since each retry re-reads the same snapshot row.
    func testUndecodableLegacyRowsAreSkippedInsteadOfFailingTheTransfer() throws {
        let storeURL = try makeLegacyStoreURL()
        let container = try ModelContainer(
            for: ClipboardHistoryItem.self,
            configurations: ModelConfiguration(url: storeURL)
        )
        let context = container.mainContext
        let keptID = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        context.insert(
            ClipboardHistoryItem(
                id: keptID,
                kind: .text,
                text: "keep me",
                previewTitle: "Keep",
                createdAt: Date(timeIntervalSince1970: 300)
            )
        )
        let unknownKind = ClipboardHistoryItem(
            kind: .text,
            text: "unmappable",
            previewTitle: "Unknown kind",
            createdAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(unknownKind)
        unknownKind.kind = "kindFromAnotherBuild"
        context.insert(
            ClipboardHistoryItem(
                kind: .file,
                previewTitle: "Broken manifest",
                createdAt: Date(timeIntervalSince1970: 100),
                filesManifest: Data("not json".utf8)
            )
        )
        try context.save()

        let defaults = try makeDefaults()
        let request = try ClipboardHistoryLegacyAdapter.makeMigrationRequest(
            storeURL: storeURL,
            defaults: defaults,
            payloadDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertEqual(request.transfer.entries.map(\.id), [keptID])
    }

    /// The reader opens the store file, so these fixtures cannot be in-memory.
    /// The directory is torn down when the test run's temporary directory is.
    private func makeLegacyStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-LegacyStore-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory.appendingPathComponent("AnyDoor.store")
    }

    private func makeDefaults() throws -> UserDefaults {
        makeTemporaryDefaults()
    }
}
