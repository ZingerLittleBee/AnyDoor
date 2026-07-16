import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class CandidateArtifactStoreTests: XCTestCase {

    private func exists(_ artifact: AtomicOutputWriter.CandidateArtifact) -> Bool {
        FileManager.default.fileExists(atPath: artifact.artifactURL.path)
    }

    func test_materialize_writesPrivateVerifiableArtifact() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        let content = Data("candidate content".utf8)

        let artifact = try store.materialize(content)

        XCTAssertEqual(try Data(contentsOf: artifact.artifactURL), content)
        XCTAssertEqual(artifact.byteCount, Int64(content.count))
        XCTAssertEqual(artifact.sha256.count, 64)

        let filePerms = try FileManager.default
            .attributesOfItem(atPath: artifact.artifactURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(filePerms, 0o600)
        let dirPerms = try FileManager.default
            .attributesOfItem(atPath: store.sessionDirectory.path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700, "session directory must be private to the user")
    }

    func test_displacedDisplayedArtifactIsDeleted() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        let item = UUID()

        let first = try store.materialize(Data("first".utf8))
        store.setDisplayed(first, forItem: item)
        let second = try store.materialize(Data("second".utf8))
        store.setDisplayed(second, forItem: item)

        XCTAssertFalse(exists(first), "displaced preview must be deleted")
        XCTAssertTrue(exists(second))
    }

    func test_artifactSharedByBothRolesSurvivesSingleRoleDisplacement() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        let item = UUID()

        // The design allows the displayed candidate and the retained
        // Best-Effort artifact to be the same file.
        let shared = try store.materialize(Data("shared".utf8))
        store.setDisplayed(shared, forItem: item)
        store.setRetainedBestEffort(shared, forItem: item)

        store.setDisplayed(nil, forItem: item)
        XCTAssertTrue(exists(shared), "still referenced as retained Best-Effort")

        store.setRetainedBestEffort(nil, forItem: item)
        XCTAssertFalse(exists(shared), "last reference gone")
    }

    func test_removeItem_deletesBothRoles() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        let item = UUID()

        let preview = try store.materialize(Data("preview".utf8))
        let bestEffort = try store.materialize(Data("best effort".utf8))
        store.setDisplayed(preview, forItem: item)
        store.setRetainedBestEffort(bestEffort, forItem: item)

        store.removeItem(item)
        XCTAssertFalse(exists(preview))
        XCTAssertFalse(exists(bestEffort))
        XCTAssertNil(store.displayed(forItem: item))
        XCTAssertNil(store.retainedBestEffort(forItem: item))
    }

    func test_pruneDisplayed_keepsSelectionAndRetainedBestEffort() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        let selected = UUID()
        let other = UUID()
        let missed = UUID()

        let selectedPreview = try store.materialize(Data("selected".utf8))
        let otherPreview = try store.materialize(Data("other".utf8))
        let retained = try store.materialize(Data("retained".utf8))
        store.setDisplayed(selectedPreview, forItem: selected)
        store.setDisplayed(otherPreview, forItem: other)
        store.setRetainedBestEffort(retained, forItem: missed)

        store.pruneDisplayed(keepingItem: selected)

        XCTAssertTrue(exists(selectedPreview), "the selected item's preview survives")
        XCTAssertFalse(exists(otherPreview), "idle previews are pruned")
        XCTAssertTrue(exists(retained), "retained Best-Effort follows its basket item, not the window")
    }

    func test_reset_removesEverything() throws {
        let store = try CandidateArtifactStore()
        let item = UUID()
        let artifact = try store.materialize(Data("gone soon".utf8))
        store.setRetainedBestEffort(artifact, forItem: item)

        store.reset()

        XCTAssertFalse(exists(artifact))
        XCTAssertNil(store.retainedBestEffort(forItem: item))
        store.reset()
    }

    func test_janitor_removesOnlyStaleSessions() throws {
        let store = try CandidateArtifactStore()
        defer { store.reset() }
        _ = try store.materialize(Data("live".utf8))

        // Fabricate a stale session directory left behind by a crash.
        let stale = CandidateArtifactStore.baseDirectory()
            .appendingPathComponent("session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: stale.appendingPathComponent("artifact-orphan"))

        // Age only the fabricated session past the 24h window.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -26 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        CandidateArtifactStore.cleanupStaleSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "stale session removed")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.sessionDirectory.path),
            "live session untouched"
        )
    }
}
