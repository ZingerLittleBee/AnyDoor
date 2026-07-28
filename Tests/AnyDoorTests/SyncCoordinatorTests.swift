import SwiftData
import XCTest
@testable import AnyDoor

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    private var folder: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var container: ModelContainer!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suiteName = "SyncCoordinatorTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let schema = Schema([KeyBinding.self, BuiltinPreference.self, Quicklink.self])
        container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    override func tearDown() async throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    func testEnableDisableLifecycle() async throws {
        let coordinator = SyncCoordinator(defaults: defaults)
        coordinator.bootstrap(modelContainer: container)
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(coordinator.engine)
        XCTAssertEqual(coordinator.status, .idle)

        coordinator.enable(folderURL: folder)
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: SyncDefaultsKeys.enabled))
        XCTAssertEqual(defaults.string(forKey: SyncDefaultsKeys.folderPath), folder.path)
        XCTAssertNotNil(coordinator.engine)
        XCTAssertNotEqual(coordinator.status, .idle)

        coordinator.disable()
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: SyncDefaultsKeys.enabled))
        XCTAssertNil(coordinator.engine)
        XCTAssertEqual(coordinator.status, .idle)
        // The folder choice is kept for the next enable.
        XCTAssertEqual(coordinator.folderPath, folder.path)
    }

    func testBootstrapWithMissingFolderReportsFailure() async throws {
        defaults.set(true, forKey: SyncDefaultsKeys.enabled)
        defaults.set(folder.path + "-gone", forKey: SyncDefaultsKeys.folderPath)

        let coordinator = SyncCoordinator(defaults: defaults)
        coordinator.bootstrap(modelContainer: container)

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertNil(coordinator.engine)
        XCTAssertEqual(coordinator.status, .failed(coordinator.statusDate ?? Date(), .folderMissing))
    }
}

private extension SyncCoordinator {
    /// Test helper: the date carried by the current status, if any.
    var statusDate: Date? {
        switch status {
        case .synced(let date), .failed(let date, _): return date
        case .idle, .waitingFirstSync: return nil
        }
    }
}
