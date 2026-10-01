@testable import ClipboardHistory
import Foundation
import os
import SwiftData
import XCTest

@testable import AnyDoor

/// The app's migration wiring against the production folder layout: pre-v2
/// payloads in `ClipboardHistory`, the encrypted store in
/// `ClipboardHistoryV2`, and the SwiftData snapshot beside them, all inside
/// one temporary `dev.bybee.AnyDoor` folder.
///
/// Reading pre-v2 payloads from anywhere but `ClipboardHistory` still
/// "succeeds": every legacy image migrates without its content. So these
/// tests materialize the migrated image and compare its bytes.
@MainActor
final class ClipboardHistoryStoreRelocationLifecycleTests: XCTestCase {
    private static let legacyText = "legacy text"
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

    func testPreV2UpgradeMigratesImagesWithTheirContent() async throws {
        let root = try makeApplicationDataDirectory()
        let png = try XCTUnwrap(Data(base64Encoded: Self.pngBase64))
        let imageName = "\(UUID().uuidString).png"
        try writeLegacyStore(in: root, imageName: imageName)
        try writePreV2Payload(png, named: imageName, in: root)
        let module = makeModule(
            in: root,
            keyStore: RelocationLifecycleKeyStore(key: nil)
        )

        let lifecycle = try await runProductionLifecycle(
            module: module,
            in: root
        )

        XCTAssertEqual(lifecycle.state, .ready)
        try await assertLegacyHistoryMigrated(
            into: module,
            in: root,
            png: png
        )
        await lifecycle.stop()
        try await module.closeStoreForTesting()
    }

    /// 4.2.0 through 4.2.5 created the store inside the pre-v2 folder and
    /// quit before the cutover finished. The next launch moves that store to
    /// its own folder, hands the pre-v2 payloads back, and the migration then
    /// finishes with every image's content.
    func testIncompleteCutoverFromAnOlderV2ReleaseFinishesInTheNewFolder()
        async throws
    {
        let root = try makeApplicationDataDirectory()
        let png = try XCTUnwrap(Data(base64Encoded: Self.pngBase64))
        let imageName = "\(UUID().uuidString).png"
        try writeLegacyStore(in: root, imageName: imageName)
        try writePreV2Payload(png, named: imageName, in: root)
        let keyStore = RelocationLifecycleKeyStore(
            key: Data(repeating: 0x5A, count: 32)
        )
        let legacyFolder = ClipboardHistoryModule.legacyPayloadDirectory(
            in: root
        )
        let olderRelease = ClipboardHistoryModule(
            testingStoreRoot: legacyFolder,
            keyStore: keyStore
        )
        let olderStatus = await olderRelease.status()
        XCTAssertEqual(olderStatus.availability, .ready)
        try await olderRelease.closeStoreForTesting()
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: legacyFolder.appendingPathComponent("history.sqlite")
                    .path
            )
        )

        let module = makeModule(in: root, keyStore: keyStore)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storeRoot(in: root)
                    .appendingPathComponent("history.sqlite").path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: legacyFolder.path
            ),
            [imageName]
        )

        let lifecycle = try await runProductionLifecycle(
            module: module,
            in: root
        )

        XCTAssertEqual(lifecycle.state, .ready)
        try await assertLegacyHistoryMigrated(
            into: module,
            in: root,
            png: png
        )
        await lifecycle.stop()
        try await module.closeStoreForTesting()
    }

    // MARK: - Fixtures

    private func makeApplicationDataDirectory() throws -> URL {
        let top = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-RelocationLifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = top.appendingPathComponent(
            "dev.bybee.AnyDoor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: top)
        }
        return root
    }

    private func storeRoot(in root: URL) -> URL {
        root.appendingPathComponent("ClipboardHistoryV2", isDirectory: true)
    }

    /// The module as production builds it, rooted in `root`.
    private func makeModule(
        in root: URL,
        keyStore: RelocationLifecycleKeyStore
    ) -> ClipboardHistoryModule {
        ClipboardHistoryModule(
            testingStoreRoot: storeRoot(in: root),
            legacyStoreRoot: ClipboardHistoryModule.legacyPayloadDirectory(
                in: root
            ),
            keyStore: keyStore
        )
    }

    /// A pre-v2 `AnyDoor.store` holding one text and one image row.
    private func writeLegacyStore(in root: URL, imageName: String) throws {
        let productionTypes: [any PersistentModel.Type] = [
            KeyBinding.self,
            BuiltinPreference.self,
            TranslationRecord.self,
            Quicklink.self,
        ] + NativePluginCatalog.modelSchemaTypes
        let container = try ModelContainer(
            for: Schema(productionTypes + [ClipboardHistoryItem.self]),
            configurations: ModelConfiguration(
                url: root.appendingPathComponent("AnyDoor.store")
            )
        )
        container.mainContext.insert(
            ClipboardHistoryItem(
                kind: .text,
                text: Self.legacyText,
                previewTitle: Self.legacyText
            )
        )
        container.mainContext.insert(
            ClipboardHistoryItem(
                kind: .image,
                fileName: imageName,
                previewTitle: "Image",
                createdAt: Date().addingTimeInterval(-1)
            )
        )
        try container.mainContext.save()
    }

    private func writePreV2Payload(
        _ data: Data,
        named name: String,
        in root: URL
    ) throws {
        let folder = ClipboardHistoryModule.legacyPayloadDirectory(in: root)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try data.write(to: folder.appendingPathComponent(name))
    }

    private func runProductionLifecycle(
        module: ClipboardHistoryModule,
        in root: URL
    ) async throws -> ClipboardHistoryLifecycle {
        let defaults = try makeDefaults()
        // Passive capture would read the real pasteboard; only the migration
        // is under test.
        ClipboardPreferences.setMonitoringEnabled(false, in: defaults)
        let lifecycle = ClipboardHistoryLifecycle.production(
            module: module,
            applicationDataDirectory: root,
            defaults: defaults,
            migrationPreparation: { .proceed }
        )
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        return lifecycle
    }

    private func assertLegacyHistoryMigrated(
        into module: ClipboardHistoryModule,
        in root: URL,
        png: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.count, 2, file: file, line: line)
        XCTAssertTrue(
            page.entries.contains { $0.previewText == Self.legacyText },
            file: file,
            line: line
        )
        let image = try XCTUnwrap(
            page.entries.first { $0.facets.contains(.image) },
            file: file,
            line: line
        )
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: image.id,
                purpose: .normalPaste
            )
        )
        let bytes = materialized.items.flatMap(\.representations).compactMap {
            representation -> Data? in
            guard case .data(_, let data) = representation else {
                return nil
            }
            return data
        }
        XCTAssertTrue(
            bytes.contains(png),
            "The legacy image migrated without its content",
            file: file,
            line: line
        )
        XCTAssertEqual(
            ClipboardHistoryLegacySource.cleanupState(in: root),
            .completed,
            file: file,
            line: line
        )
        // The pre-v2 folder ends up holding nothing a pre-v2 release could
        // sweep: no store, and no payload the migration still needs.
        let legacyFolder = ClipboardHistoryModule.legacyPayloadDirectory(
            in: root
        )
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(
                atPath: legacyFolder.path
            )) ?? [],
            [],
            file: file,
            line: line
        )
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "ClipboardHistoryStoreRelocationLifecycleTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// In-memory stand-in for the Keychain item.
private final class RelocationLifecycleKeyStore: ClipboardHistoryMasterKeyStoring,
    Sendable
{
    private let key: OSAllocatedUnfairLock<Data?>

    init(key: Data?) {
        self.key = OSAllocatedUnfairLock(initialState: key)
    }

    func load() -> ClipboardHistoryMasterKeyResult {
        guard let key = key.withLock({ $0 }) else { return .missing }
        return .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        let created = Data(repeating: 0x5A, count: 32)
        key.withLock { $0 = created }
        return .key(created)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        key.withLock { $0 = nil }
        return .missing
    }
}
