import ClipboardHistoryTestSupport
import Foundation
import Darwin
import ClipboardHistory
import SwiftData
import XCTest

@testable import AnyDoor

private struct DisposableClipboardFixture {
    enum ValidationError: Error { case unsafeHome, unexpectedPath, notFresh, notFixture }

    let home: URL
    let storeDirectory: URL
    private var markerURL: URL { storeDirectory.appendingPathComponent(".gui-fixture-v1") }
    private static let marker = Data("AnyDoor disposable clipboard fixture v1\n".utf8)

    init(fixedHome: String?, accountHome: URL, support: URL, v2: URL, legacy: URL) throws {
        guard let fixedHome, !fixedHome.isEmpty, (fixedHome as NSString).isAbsolutePath else {
            throw ValidationError.unsafeHome
        }
        home = URL(fileURLWithPath: fixedHome).standardizedFileURL.resolvingSymlinksInPath()
        let account = accountHome.standardizedFileURL.resolvingSymlinksInPath()
        guard home.path != "/", !account.pathComponents.starts(with: home.pathComponents) else {
            throw ValidationError.unsafeHome
        }
        let expectedSupport = home.appendingPathComponent("Library/Application Support")
        storeDirectory = expectedSupport.appendingPathComponent("dev.bybee.AnyDoor")
        for (actual, expected) in [
            (support, expectedSupport),
            (v2, storeDirectory.appendingPathComponent("ClipboardHistoryV2")),
            (legacy, storeDirectory.appendingPathComponent("ClipboardHistory")),
        ] {
            guard actual.standardizedFileURL.resolvingSymlinksInPath().path == expected.path else {
                throw ValidationError.unexpectedPath
            }
        }
    }

    static func current() throws -> Self {
        let accountHome = try XCTUnwrap(getpwuid(getuid())?.pointee.pw_dir)
        return try Self(
            fixedHome: ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
            accountHome: URL(fileURLWithPath: String(cString: accountHome)),
            support: try XCTUnwrap(FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first),
            v2: ClipboardHistoryModule.defaultStoreRoot,
            legacy: ClipboardHistoryModule.legacyPayloadDirectory
        )
    }

    func requireFreshDirectory() throws {
        if FileManager.default.fileExists(atPath: storeDirectory.path),
           !(try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)).isEmpty {
            throw ValidationError.notFresh
        }
    }

    func markCreated() throws { try Self.marker.write(to: markerURL, options: .atomic) }

    func requireCreatedFixture() throws {
        guard try Data(contentsOf: markerURL) == Self.marker,
              ClipboardHistoryLegacySource.cleanupState(in: storeDirectory) == .incomplete else {
            throw ValidationError.notFixture
        }
    }
}

@MainActor
final class ClipboardHistoryGUIFixtureTests: XCTestCase {
    func testDisposablePathsRejectUnsafeRootsAndMismatchedLocations() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .standardizedFileURL.resolvingSymlinksInPath()
        let support = home.appendingPathComponent("Library/Application Support")
        let store = support.appendingPathComponent("dev.bybee.AnyDoor")
        let v2 = store.appendingPathComponent("ClipboardHistoryV2")
        let legacy = store.appendingPathComponent("ClipboardHistory")
        let account = URL(fileURLWithPath: "/Users/fixture-account")
        for unsafe in [nil, "", "relative/home", "/", account.path, "/Users"] as [String?] {
            XCTAssertThrowsError(try DisposableClipboardFixture(
                fixedHome: unsafe, accountHome: account, support: support, v2: v2, legacy: legacy
            ))
        }
        for (badSupport, badV2, badLegacy) in [
            (URL(fileURLWithPath: home.path + "-sibling/Library/Application Support"), v2, legacy),
            (support, legacy, legacy), (support, v2, v2),
        ] {
            XCTAssertThrowsError(try DisposableClipboardFixture(
                fixedHome: home.path, accountHome: account,
                support: badSupport, v2: badV2, legacy: badLegacy
            ))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))
        let fixture = try DisposableClipboardFixture(
            fixedHome: home.path, accountHome: account, support: support, v2: v2, legacy: legacy
        )
        try fixture.requireFreshDirectory()
        XCTAssertThrowsError(try fixture.requireCreatedFixture())
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path))

        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sentinel = store.appendingPathComponent("AnyDoor.store-wal")
        try Data("do not touch".utf8).write(to: sentinel)
        XCTAssertThrowsError(try fixture.requireFreshDirectory())
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("do not touch".utf8))
    }

    func testRunDisposableLegacyMigration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIPBOARD_HISTORY_GUI_MIGRATION"] == "1" else {
            throw XCTSkip(
                "Set CLIPBOARD_HISTORY_GUI_MIGRATION=1 with CFFIXED_USER_HOME"
            )
        }
        let fixture = try DisposableClipboardFixture.current()
        try fixture.requireCreatedFixture()
        let storeDirectory = fixture.storeDirectory
        let storeURL = storeDirectory.appendingPathComponent("AnyDoor.store")
        let legacySource = try ClipboardHistoryLegacySource.openForMigration(
            applicationSupportDirectory: storeDirectory,
            productionStoreURL: storeURL,
            payloadDirectory: ClipboardHistoryModule.legacyPayloadDirectory
        )
        let request = try legacySource.makeMigrationRequest()
        let module = trackClipboardHistoryModule(ClipboardHistoryModule())
        let outcome = try await module.migrateLegacy(request)
        let cleanup = try await module.cleanupLegacyPayloads(
            in: request.payloadDirectory
        )
        XCTAssertTrue(cleanup.canDeleteLegacyRows)
        try ClipboardHistoryLegacySource.finishMigration(in: storeDirectory)
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.count, 100)
        print("CLIPBOARD_HISTORY_GUI_MIGRATION=\(outcome)")
    }

    func testCreateDisposableLegacyMigrationFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CLIPBOARD_HISTORY_GUI_FIXTURE"] == "1" else {
            throw XCTSkip(
                "Set CLIPBOARD_HISTORY_GUI_FIXTURE=1 with CFFIXED_USER_HOME"
            )
        }
        let fixture = try DisposableClipboardFixture.current()
        try fixture.requireFreshDirectory()
        let storeDirectory = fixture.storeDirectory
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        let storeURL = storeDirectory.appendingPathComponent("AnyDoor.store")
        let schema = Schema(
            [
                KeyBinding.self,
                BuiltinPreference.self,
                ClipboardHistoryItem.self,
                TranslationRecord.self,
                Quicklink.self,
            ]
                + NativePluginCatalog.modelSchemaTypes
        )
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(url: storeURL)
        )
        container.mainContext.insert(
            KeyBinding(
                keyCode: 122,
                modifierFlags: 0,
                appBundleID: "com.apple.finder",
                appName: "Finder",
                appPath: "/System/Library/CoreServices/Finder.app"
            )
        )
        for index in 0..<160 {
            let marker: String
            switch index % 4 {
            case 0:
                marker = "甲"
            case 1:
                marker = "乙丙"
            case 2:
                marker = "interplanetary-substring"
            default:
                marker = "ordinary"
            }
            let text = "GUI fixture \(index) \(marker)"
            container.mainContext.insert(
                ClipboardHistoryItem(
                    kind: .text,
                    text: text,
                    previewTitle: text,
                    createdAt: Date().addingTimeInterval(
                        TimeInterval(-index)
                    ),
                    sourceBundleID: index.isMultiple(of: 2)
                        ? "com.apple.Safari"
                        : "com.apple.Notes",
                    sourceAppName: index.isMultiple(of: 2)
                        ? "Safari"
                        : "Notes",
                    isFavorite: index.isMultiple(of: 17)
                )
            )
        }
        let legacyPayloadName = "owned-restore-fixture.txt"
        try FileManager.default.createDirectory(
            at: ClipboardHistoryModule.legacyPayloadDirectory,
            withIntermediateDirectories: true
        )
        let legacyPayload = Data(
            "AnyDoor owned-file restore acceptance\n".utf8
        )
        try legacyPayload.write(
            to: ClipboardHistoryModule.legacyPayloadDirectory
                .appendingPathComponent(legacyPayloadName)
        )
        let missingOriginalURL = fixture.home
            .appendingPathComponent("missing-original", isDirectory: true)
            .appendingPathComponent("restored-acceptance.txt")
        let manifest = try JSONEncoder().encode([
            ClipboardFileEntry(
                storedName: legacyPayloadName,
                originalName: "restored-acceptance.txt",
                originalPath: missingOriginalURL.path
            )
        ])
        container.mainContext.insert(
            ClipboardHistoryItem(
                kind: .file,
                fileName: "restored-acceptance.txt",
                previewTitle: "Owned restore fixture",
                createdAt: Date().addingTimeInterval(-161),
                sourceBundleID: "com.apple.finder",
                sourceAppName: "Finder",
                filesManifest: manifest
            )
        )
        try container.mainContext.save()
        try fixture.markCreated()
        print("CLIPBOARD_HISTORY_GUI_FIXTURE_ROOT=\(fixture.home.path)")
    }
}
