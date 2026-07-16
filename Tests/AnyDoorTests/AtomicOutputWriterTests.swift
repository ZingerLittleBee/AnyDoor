import CryptoKit
import XCTest
@testable import AnyDoor
@testable import ImageConversionPlugin

final class AtomicOutputWriterTests: XCTestCase {
    private var directory: URL!
    private var artifactDirectory: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtomicWriterTests-\(UUID().uuidString)", isDirectory: true)
        directory = root.appendingPathComponent("destination", isDirectory: true)
        artifactDirectory = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions in case a test dropped write access.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: directory.path
        )
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func makeArtifact(
        _ content: Data = Data("candidate bytes".utf8),
        byteCount: Int64? = nil,
        sha256: String? = nil
    ) throws -> AtomicOutputWriter.CandidateArtifact {
        let url = artifactDirectory.appendingPathComponent("artifact-\(UUID().uuidString)")
        try content.write(to: url)
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        return AtomicOutputWriter.CandidateArtifact(
            artifactURL: url,
            byteCount: byteCount ?? Int64(content.count),
            sha256: sha256 ?? digest
        )
    }

    private func destination(base: String = "photo", ext: String = "jpg") -> AtomicOutputWriter.DestinationPolicy {
        AtomicOutputWriter.DestinationPolicy(directory: directory, baseName: base, fileExtension: ext)
    }

    private func directoryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
    }

    // MARK: - Success

    func test_commit_writesVerifiedFileAtFirstName_andLeavesNoStaging() throws {
        let content = Data("hello final file".utf8)
        let artifact = try makeArtifact(content)
        let output = try AtomicOutputWriter().commit(artifact, to: destination())

        XCTAssertEqual(output.url.lastPathComponent, "photo.jpg")
        XCTAssertEqual(try Data(contentsOf: output.url), content)
        XCTAssertEqual(output.byteCount, Int64(content.count))
        XCTAssertEqual(output.sha256, artifact.sha256)
        XCTAssertEqual(try directoryEntries(), ["photo.jpg"], "no staging file may remain")
    }

    func test_commit_streamsLargeArtifact() throws {
        // Larger than one 1 MiB chunk so the write loop actually iterates.
        let content = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 253) })
        let artifact = try makeArtifact(content)
        let output = try AtomicOutputWriter().commit(artifact, to: destination())
        XCTAssertEqual(try Data(contentsOf: output.url), content)
    }

    // MARK: - Collisions

    func test_commit_existingFileIsNeverReplaced_nextFinderNameUsed() throws {
        let preexisting = Data("precious user data".utf8)
        try preexisting.write(to: directory.appendingPathComponent("photo.jpg"))

        let output = try AtomicOutputWriter().commit(try makeArtifact(), to: destination())

        XCTAssertEqual(output.url.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent("photo.jpg")),
            preexisting,
            "the pre-existing file must remain byte-for-byte untouched"
        )
    }

    func test_commit_walksFinderNamesInOrder() throws {
        try Data("a".utf8).write(to: directory.appendingPathComponent("photo.jpg"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("photo 2.jpg"))

        let output = try AtomicOutputWriter().commit(try makeArtifact(), to: destination())
        XCTAssertEqual(output.url.lastPathComponent, "photo 3.jpg")
    }

    func test_commit_danglingSymlinkAtFinalNameIsACollision() throws {
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("photo.jpg"),
            withDestinationURL: directory.appendingPathComponent("does-not-exist")
        )

        let output = try AtomicOutputWriter().commit(try makeArtifact(), to: destination())
        XCTAssertEqual(output.url.lastPathComponent, "photo 2.jpg")
    }

    // MARK: - Verification failures

    func test_commit_digestMismatch_leavesNoOutputAndNoStaging() throws {
        let artifact = try makeArtifact(sha256: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try AtomicOutputWriter().commit(artifact, to: destination())) { error in
            XCTAssertEqual(error as? AtomicOutputWriterError, .contentMismatch)
        }
        XCTAssertEqual(try directoryEntries(), [])
    }

    func test_commit_byteCountMismatch_leavesNoOutputAndNoStaging() throws {
        let artifact = try makeArtifact(byteCount: 999)
        XCTAssertThrowsError(try AtomicOutputWriter().commit(artifact, to: destination())) { error in
            XCTAssertEqual(error as? AtomicOutputWriterError, .contentMismatch)
        }
        XCTAssertEqual(try directoryEntries(), [])
    }

    func test_commit_missingArtifact_throwsArtifactUnreadable() throws {
        let artifact = AtomicOutputWriter.CandidateArtifact(
            artifactURL: artifactDirectory.appendingPathComponent("gone"),
            byteCount: 1,
            sha256: String(repeating: "0", count: 64)
        )
        XCTAssertThrowsError(try AtomicOutputWriter().commit(artifact, to: destination())) { error in
            guard case .artifactUnreadable = error as? AtomicOutputWriterError else {
                return XCTFail("expected artifactUnreadable, got \(error)")
            }
        }
        XCTAssertEqual(try directoryEntries(), [])
    }

    // MARK: - Cancellation

    func test_commit_cancelledAtFinalGate_producesNoFile() throws {
        let artifact = try makeArtifact()
        XCTAssertThrowsError(
            try AtomicOutputWriter().commit(artifact, to: destination(), isCancelled: { true })
        ) { error in
            XCTAssertEqual(error as? AtomicOutputWriterError, .cancelled)
        }
        XCTAssertEqual(try directoryEntries(), [], "cancellation before commit leaves nothing behind")
    }

    // MARK: - Destination problems

    func test_commit_missingDirectory_throwsDirectoryUnavailable() throws {
        let gone = destination()
        try FileManager.default.removeItem(at: directory)
        XCTAssertThrowsError(try AtomicOutputWriter().commit(try makeArtifact(), to: gone)) { error in
            guard case .directoryUnavailable = error as? AtomicOutputWriterError else {
                return XCTFail("expected directoryUnavailable, got \(error)")
            }
        }
    }

    func test_commit_readOnlyDirectory_failsWithoutTouchingIt() throws {
        try Data("existing".utf8).write(to: directory.appendingPathComponent("photo.jpg"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: directory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: directory.path
            )
        }

        XCTAssertThrowsError(try AtomicOutputWriter().commit(try makeArtifact(), to: destination())) { error in
            guard case .stagingFailed = error as? AtomicOutputWriterError else {
                return XCTFail("expected stagingFailed, got \(error)")
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertEqual(try directoryEntries(), ["photo.jpg"])
    }

    // MARK: - Concurrency

    func test_commit_concurrentClaimsOfOneName_neverOverwriteEachOther() throws {
        // Ten writers race for the same base name; every one must land on a
        // distinct final name with its own intact content.
        let contents = (0..<10).map { Data("writer \($0) content".utf8) }
        let artifacts = try contents.map { try makeArtifact($0) }
        let policy = destination()

        let queue = DispatchQueue(label: "race", attributes: .concurrent)
        let group = DispatchGroup()
        for artifact in artifacts {
            queue.async(group: group) {
                _ = try? AtomicOutputWriter().commit(artifact, to: policy)
            }
        }
        group.wait()

        let entries = try directoryEntries().sorted()
        XCTAssertEqual(entries.count, 10, "all ten writers must commit distinct files")
        let readBack = try Set(entries.map { try Data(contentsOf: directory.appendingPathComponent($0)) })
        XCTAssertEqual(readBack, Set(contents), "every committed file keeps its own content")
    }
}
