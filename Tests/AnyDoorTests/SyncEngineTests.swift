import SwiftData
import XCTest
@testable import AnyDoor
@testable import PluginInterface

/// End-to-end engine tests: real in-memory SwiftData containers, real
/// UserDefaults suites, and a real shared temp folder as the transport — two
/// "devices" converging through actual state files, nothing mocked.
@MainActor
final class SyncEngineTests: XCTestCase {

    private final class WallClock {
        var now: Int64 = 1_000
    }

    private struct Device {
        let id: String
        let container: ModelContainer
        let defaults: UserDefaults
        let suiteName: String
        let engine: SyncEngine
        let wall: WallClock
        @MainActor var context: ModelContext { container.mainContext }
    }

    private var folder: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncEngineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for name in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        suiteNames = []
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeDevice(_ id: String) throws -> Device {
        let schema = Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "SyncEngineTests-\(id)-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let wall = WallClock()
        let stateURL = folder.appendingPathComponent("local-state-\(id).json")
        let engine = SyncEngine(
            config: SyncEngine.Configuration(deviceID: id, deviceName: id),
            context: container.mainContext,
            defaults: defaults,
            transport: SyncFolderTransport(folderURL: folder),
            stateStore: SyncLocalStateStore(url: stateURL),
            appPathResolver: { _ in nil },
            reconcileRuntime: {},
            wallNow: { wall.now }
        )
        return Device(
            id: id, container: container, defaults: defaults,
            suiteName: suiteName, engine: engine, wall: wall
        )
    }

    private let prefKey = BuiltinItem.allCases[0].rawValue

    /// Seed the preference row the seeder would have created on every machine.
    private func seedPreference(_ device: Device) throws {
        device.context.insert(BuiltinPreference(itemKey: prefKey, displayOrder: 100))
        try device.context.save()
    }

    // MARK: - Scenarios

    func testCreateAndEditPropagateAcrossDevices() async throws {
        let a = try makeDevice("device-a")
        let b = try makeDevice("device-b")
        try seedPreference(a)
        try seedPreference(b)

        // Machine A configures everything a bit later than B's baseline
        // stamps, so A's records win the seeded-row conflict.
        a.wall.now = 2_000
        a.context.insert(KeyBinding(
            keyCode: 4, modifierFlags: 256,
            appBundleID: "com.apple.Safari", appName: "Safari", appPath: "/Applications/Safari.app",
            isEnabled: true, isVisible: true, displayOrder: 100
        ))
        let quicklinkID = UUID()
        a.context.insert(Quicklink(
            id: quicklinkID, name: "GitHub", keyword: "gh",
            link: "https://github.com", openWithBundleID: nil,
            keyCode: nil, modifierFlags: nil,
            isVisible: true, displayOrder: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        if let pref = try a.context.fetch(FetchDescriptor<BuiltinPreference>()).first {
            pref.keyCode = 9
            pref.modifierFlags = 256
        }
        try a.context.save()
        a.defaults.set("custom-icon", forKey: "menuBar.iconName")

        await a.engine.tick()
        await b.engine.tick()

        let bBindings = try b.context.fetch(FetchDescriptor<KeyBinding>())
        XCTAssertEqual(bBindings.map(\.appBundleID), ["com.apple.Safari"])
        let bQuicklinks = try b.context.fetch(FetchDescriptor<Quicklink>())
        XCTAssertEqual(bQuicklinks.map(\.id), [quicklinkID])
        XCTAssertEqual(bQuicklinks.first?.keyword, "gh")
        let bPref = try b.context.fetch(FetchDescriptor<BuiltinPreference>()).first
        XCTAssertEqual(bPref?.keyCode, 9)
        XCTAssertEqual(b.defaults.string(forKey: "menuBar.iconName"), "custom-icon")
    }

    func testDeletePropagatesViaTombstone() async throws {
        let a = try makeDevice("device-a")
        let b = try makeDevice("device-b")

        a.wall.now = 2_000
        let quicklinkID = UUID()
        a.context.insert(Quicklink(
            id: quicklinkID, name: "GitHub", keyword: nil,
            link: "https://github.com", openWithBundleID: nil,
            keyCode: nil, modifierFlags: nil,
            isVisible: true, displayOrder: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try a.context.save()
        await a.engine.tick()
        await b.engine.tick()
        XCTAssertEqual(try b.context.fetch(FetchDescriptor<Quicklink>()).count, 1)

        // Delete on A; B must converge to the deletion, not resurrect it.
        a.wall.now = 3_000
        for row in try a.context.fetch(FetchDescriptor<Quicklink>()) {
            a.context.delete(row)
        }
        try a.context.save()
        await a.engine.tick()
        await b.engine.tick()

        XCTAssertTrue(try b.context.fetch(FetchDescriptor<Quicklink>()).isEmpty)
        XCTAssertEqual(
            b.engine.document.entries[.quicklink(id: quicklinkID)]?.isTombstone,
            true
        )

        // A ticks again after B's write: the deletion must hold everywhere.
        await a.engine.tick()
        XCTAssertTrue(try a.context.fetch(FetchDescriptor<Quicklink>()).isEmpty)
    }

    func testSameRecordConflictResolvesToNewerClockEverywhere() async throws {
        let a = try makeDevice("device-a")
        let b = try makeDevice("device-b")

        a.wall.now = 5_000
        a.defaults.set("a-name", forKey: "menuBar.iconName")
        await a.engine.tick()

        b.wall.now = 6_000
        b.defaults.set("b-name", forKey: "menuBar.iconName")
        await b.engine.tick()
        await a.engine.tick()

        XCTAssertEqual(a.defaults.string(forKey: "menuBar.iconName"), "b-name")
        XCTAssertEqual(b.defaults.string(forKey: "menuBar.iconName"), "b-name")
    }

    func testConcurrentKeywordCollisionResolvesDeterministically() async throws {
        let a = try makeDevice("device-a")
        let b = try makeDevice("device-b")

        let idA = UUID()
        let idB = UUID()
        a.wall.now = 7_000
        a.context.insert(Quicklink(
            id: idA, name: "A's GitHub", keyword: "gh",
            link: "https://github.com/a", openWithBundleID: nil,
            keyCode: nil, modifierFlags: nil,
            isVisible: true, displayOrder: 100,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        try a.context.save()
        b.wall.now = 8_000
        b.context.insert(Quicklink(
            id: idB, name: "B's GitHub", keyword: "GH",
            link: "https://github.com/b", openWithBundleID: nil,
            keyCode: nil, modifierFlags: nil,
            isVisible: true, displayOrder: 200,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        ))
        try b.context.save()

        await a.engine.tick()
        await b.engine.tick()
        await a.engine.tick()

        for device in [a, b] {
            let rows = try device.context.fetch(FetchDescriptor<Quicklink>())
            XCTAssertEqual(rows.count, 2, "both rows survive on \(device.id)")
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            XCTAssertEqual(byID[idB]?.keyword, "GH", "newer row keeps the keyword on \(device.id)")
            XCTAssertNil(byID[idA]?.keyword, "older row's keyword cleared on \(device.id)")
        }
    }

    func testCorruptAndForeignFilesAreIgnored() async throws {
        let a = try makeDevice("device-a")
        try "not json at all".write(
            to: folder.appendingPathComponent("AnyDoor-SyncState-evil.json"),
            atomically: true, encoding: .utf8
        )
        try "user note".write(
            to: folder.appendingPathComponent("notes.txt"),
            atomically: true, encoding: .utf8
        )
        try "conflict artifact".write(
            to: folder.appendingPathComponent("AnyDoor-SyncState-x (conflicted copy).json"),
            atomically: true, encoding: .utf8
        )

        a.wall.now = 2_000
        a.defaults.set("custom-icon", forKey: "menuBar.iconName")
        await a.engine.tick()

        XCTAssertEqual(a.defaults.string(forKey: "menuBar.iconName"), "custom-icon")
        XCTAssertNotNil(
            a.engine.document.entries[.setting(key: "menuBar.iconName")],
            "engine keeps working despite garbage files in the folder"
        )
    }

    func testUnknownSettingKeyIsCarriedNotTombstoned() async throws {
        let a = try makeDevice("device-a")

        // A peer running a newer app version syncs a setting this build
        // doesn't know. It must survive round trips, never be tombstoned.
        let futureKey = SyncKey.setting(key: "future.someNewSetting")
        var peer = SyncDocument(deviceID: "device-c", deviceName: "C")
        peer.entries[futureKey] = SyncEntry(
            payload: .setting(.bool(true)),
            clock: SyncTimestamp(wallMillis: 9_000, counter: 0, deviceID: "device-c")
        )
        try SyncStateCodec.encode(peer).write(
            to: folder.appendingPathComponent(SyncFolderTransport.fileName(forDeviceID: "device-c")),
            options: .atomic
        )

        await a.engine.tick()
        await a.engine.tick()

        let entry = try XCTUnwrap(a.engine.document.entries[futureKey])
        XCTAssertFalse(entry.isTombstone)
        XCTAssertNil(a.defaults.object(forKey: "future.someNewSetting"),
                     "an unknown setting is carried, not applied")
    }

    func testConvergedTickIsStableNoRestampsNoRewrites() async throws {
        let a = try makeDevice("device-a")
        let b = try makeDevice("device-b")
        a.wall.now = 2_000
        a.defaults.set("custom-icon", forKey: "menuBar.iconName")
        await a.engine.tick()
        await b.engine.tick()
        await a.engine.tick()

        let ownFile = folder.appendingPathComponent(
            SyncFolderTransport.fileName(forDeviceID: "device-a")
        )
        let bytesBefore = try Data(contentsOf: ownFile)
        let entriesBefore = a.engine.document.entries

        a.wall.now = 9_999
        await a.engine.tick()

        XCTAssertEqual(a.engine.document.entries, entriesBefore,
                       "a converged tick must not restamp anything")
        XCTAssertEqual(try Data(contentsOf: ownFile), bytesBefore,
                       "a converged tick must not rewrite the state file")
    }

    func testDocumentAndClockSurviveRestart() async throws {
        let a = try makeDevice("device-a")
        a.wall.now = 2_000
        a.defaults.set("custom-icon", forKey: "menuBar.iconName")
        await a.engine.tick()

        // Same state store, fresh engine — simulates an app relaunch.
        let relaunched = SyncEngine(
            config: SyncEngine.Configuration(deviceID: "device-a", deviceName: "device-a"),
            context: a.context,
            defaults: a.defaults,
            transport: SyncFolderTransport(folderURL: folder),
            stateStore: SyncLocalStateStore(url: folder.appendingPathComponent("local-state-device-a.json")),
            appPathResolver: { _ in nil },
            reconcileRuntime: {},
            wallNow: { a.wall.now }
        )
        XCTAssertEqual(relaunched.document.entries, a.engine.document.entries)
    }
}
