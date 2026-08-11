import Foundation
import XCTest

final class FeedPublicationTests: XCTestCase {
    func testRejectsSnapshotThatDropsNewerStableHead() throws {
        let live = try writeFeed(stable: "4.1.299", beta: "4.2.1")
        let candidate = try writeFeed(stable: "4.1.199", beta: "4.2.2")

        let result = try verify(live: live, candidate: candidate)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("roll back stable"))
    }

    func testAllowsEitherChannelToAdvanceWithoutDroppingTheOther() throws {
        let live = try writeFeed(stable: "4.1.199", beta: "4.2.1")
        let candidate = try writeFeed(stable: "4.1.199", beta: "4.2.2")

        let result = try verify(live: live, candidate: candidate)

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testBootstrapGuardAllowsOnlyMissingEndpoint() throws {
        let missing = try verifyBootstrap(httpStatus: "404")
        XCTAssertEqual(missing.status, 0, missing.stderr)

        let existing = try verifyBootstrap(httpStatus: "200")
        XCTAssertNotEqual(existing.status, 0)
        XCTAssertTrue(existing.stderr.contains("Bootstrap refused"))
    }

    func testBootstrapGuardFailsClosedWhenEndpointCannotBeChecked() throws {
        let result = try verifyBootstrap(httpStatus: nil)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Cannot verify"))
    }

    private func verify(live: URL, candidate: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/verify-feed-publication.py")
        process.arguments = ["--live", live.path, "--candidate", candidate.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func verifyBootstrap(httpStatus: String?) throws -> (status: Int32, stderr: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let curl = directory.appendingPathComponent("curl")
        let implementation = if let httpStatus {
            "#!/bin/sh\nprintf '%s' '\(httpStatus)'\n"
        } else {
            "#!/bin/sh\nexit 7\n"
        }
        try Data(implementation.utf8).write(to: curl)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: curl.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        let stderr = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/verify-feed-bootstrap.sh")
        process.arguments = ["https://example.invalid/appcast.xml"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(directory.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        process.environment = environment
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func writeFeed(stable: String, beta: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).xml")
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
          <item><sparkle:version>\(stable)</sparkle:version></item>
          <item><sparkle:version>\(beta)</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
        </channel></rss>
        """
        try Data(xml.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
