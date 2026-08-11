import Foundation
import Sparkle
import XCTest

final class ReleaseVersionTests: XCTestCase {
    func testSparkleComparatorPreservesReleaseLineOrdering() {
        let comparator = SUStandardVersionComparator.default
        let ordered = ["4.1.199", "4.2.1", "4.2.98", "4.2.99", "4.2.199"]

        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertEqual(comparator.compareVersion(pair.0, toVersion: pair.1), .orderedAscending)
        }
    }

    func testStableVersionUsesReservedStableSlot() throws {
        let result = try resolve("4.2.1")

        XCTAssertEqual(result, ["4.2.1", "stable", "4.2.1", "4.2.199", "4.2.1"])
    }

    func testBetaVersionUsesBetaNumberAsSlot() throws {
        let result = try resolve("4.2.0-beta.7")

        XCTAssertEqual(result, ["4.2.0-beta.7", "beta", "4.2.0", "4.2.7", "4.2.0 Beta 7"])
    }

    func testBetaSlotBoundsAreEnforced() throws {
        for version in ["4.2.0-beta.0", "4.2.0-beta.99", "4.2.0-beta.100"] {
            let result = try runResolver(version)
            XCTAssertNotEqual(result.status, 0, version)
        }
    }

    func testUnknownPrereleaseSuffixIsRejected() throws {
        let result = try runResolver("4.2.0-rc.1")

        XCTAssertNotEqual(result.status, 0)
    }

    func testBumpScriptWritesAppleCompliantBetaBundleVersions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let plist = directory.appendingPathComponent("Info.plist")
        let initial: [String: Any] = [
            "CFBundleShortVersionString": "4.1.0",
            "CFBundleVersion": "4.1.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: initial,
            format: .xml,
            options: 0
        )
        try data.write(to: plist)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let process = Process()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/bump-version.sh")
        process.arguments = ["4.2.0-beta.1"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PLIST": plist.path]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let updatedData = try Data(contentsOf: plist)
        let updated = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: updatedData, format: nil) as? [String: Any]
        )
        XCTAssertEqual(updated["CFBundleShortVersionString"] as? String, "4.2.0")
        XCTAssertEqual(updated["CFBundleVersion"] as? String, "4.2.1")
    }

    private func resolve(_ version: String) throws -> [String] {
        let result = try runResolver(version)
        XCTAssertEqual(result.status, 0, result.stderr)
        return result.stdout.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private func runResolver(_ version: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = repositoryRoot.appendingPathComponent("scripts/resolve-release-version.sh")
        process.arguments = [version]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .newlines),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
