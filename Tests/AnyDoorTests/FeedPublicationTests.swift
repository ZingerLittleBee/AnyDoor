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
