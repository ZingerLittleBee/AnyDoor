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

        coordinator.configureFolder(folder)
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

    func testConfigureWebDAVValidationAndPersistence() async throws {
        let service = "SyncCoordinatorTests-\(UUID().uuidString)"
        let credentials = SyncWebDAVCredentialStore(service: service)
        defer { credentials.deletePassword() }
        let coordinator = SyncCoordinator(defaults: defaults, credentialStore: credentials)
        coordinator.bootstrap(modelContainer: container)

        // http and empty usernames are rejected without enabling anything.
        XCTAssertFalse(coordinator.configureWebDAV(
            urlString: "http://insecure.example.com/dav", username: "bee", password: "pw"
        ))
        XCTAssertFalse(coordinator.configureWebDAV(
            urlString: "https://dav.example.invalid/AnyDoor", username: " ", password: "pw"
        ))
        guard case .failed(_, .invalidConfiguration) = coordinator.status else {
            return XCTFail("expected invalidConfiguration, got \(coordinator.status)")
        }
        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertNil(coordinator.engine)

        XCTAssertTrue(coordinator.configureWebDAV(
            urlString: "https://dav.example.invalid/AnyDoor", username: "bee", password: "pw"
        ))
        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(coordinator.transportKind, .webdav)
        XCTAssertEqual(
            defaults.string(forKey: SyncDefaultsKeys.webdavURL),
            "https://dav.example.invalid/AnyDoor"
        )
        XCTAssertEqual(credentials.password(), "pw")
        XCTAssertNotNil(coordinator.engine)

        // Re-saving with a blank password keeps the stored secret.
        XCTAssertTrue(coordinator.configureWebDAV(
            urlString: "https://dav.example.invalid/Other", username: "bee", password: "  "
        ))
        XCTAssertEqual(credentials.password(), "pw")

        coordinator.disable()
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
