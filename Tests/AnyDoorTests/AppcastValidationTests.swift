import Foundation
import XCTest

final class AppcastValidationTests: XCTestCase {
    func testDisplayRewriteChangesOnlyTheRequestedItem() throws {
        let appcast = try makeAppcast(betaChannel: "beta")
        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/set-appcast-display.py")
        process.arguments = [
            "--appcast", appcast.path,
            "--build-version", "4.2.1",
            "--display-version", "4.2.0 Beta 2",
        ]
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let updated = try String(contentsOf: appcast, encoding: .utf8)
        XCTAssertTrue(updated.contains("<title>4.1.1</title>"))
        XCTAssertTrue(updated.contains("<sparkle:shortVersionString>4.1.1</sparkle:shortVersionString>"))
        XCTAssertTrue(updated.contains("<title>4.2.0 Beta 2</title>"))
        XCTAssertTrue(updated.contains("<sparkle:shortVersionString>4.2.0 Beta 2</sparkle:shortVersionString>"))
    }

    func testValidMixedChannelFeedPasses() throws {
        let appcast = try makeAppcast(betaChannel: "beta")

        let result = try validate(appcast)

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testBetaWithoutChannelFails() throws {
        let appcast = try makeAppcast(betaChannel: nil)

        let result = try validate(appcast)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("candidate channel"))
    }

    private func validate(_ appcast: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/validate-appcast.py")
        process.arguments = [
            "--appcast", appcast.path,
            "--release-id", "4.2.0-beta.1",
            "--channel", "beta",
            "--short-version", "4.2.0",
            "--build-version", "4.2.1",
            "--display-version", "4.2.0 Beta 1",
        ]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func makeAppcast(betaChannel: String?) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let channel = betaChannel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? ""
        let xml = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
          <channel>
            <item>
              <title>4.1.1</title>
              <sparkle:version>4.1.199</sparkle:version>
              <sparkle:shortVersionString>4.1.1</sparkle:shortVersionString>
              <enclosure url="https://example.com/stable.zip" sparkle:edSignature="stable" />
            </item>
            <item>
              <title>4.2.0 Beta 1</title>
              <sparkle:version>4.2.1</sparkle:version>
              <sparkle:shortVersionString>4.2.0 Beta 1</sparkle:shortVersionString>
              \(channel)
              <enclosure url="https://github.com/ZingerLittleBee/AnyDoor/releases/download/v4.2.0-beta.1/AnyDoor-4.2.0-beta.1.zip" sparkle:edSignature="beta" />
            </item>
          </channel>
        </rss>
        """
        let url = directory.appendingPathComponent("appcast.xml")
        try Data(xml.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
