import Foundation
import XCTest
import os

final class TemporaryDefaultsTests: XCTestCase {
    @MainActor
    func testSuiteStoresItsPlistInsideItsOwnDirectory() async throws {
        let label = "probe-\(UUID().uuidString)"
        let suite = makeTemporaryDefaultsSuite(label)
        suite.makeDefaults().set("kept", forKey: "value")

        XCTAssertEqual(suite.makeDefaults().string(forKey: "value"), "kept")
        await waitUntil("the suite plist is written", timeout: 10) {
            FileManager.default.fileExists(atPath: suite.name + ".plist")
        }
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        let leaked = try FileManager.default
            .contentsOfDirectory(atPath: preferences.path)
            .filter { $0.contains(label) }
        XCTAssertEqual(leaked, [], "the suite also wrote to \(preferences.path)")
    }

    @MainActor
    func testRemoveDeletesTheValuesAndTheDirectory() async {
        let suite = TemporaryDefaultsSuite()
        // Covers an early failure; removing twice is harmless.
        defer { suite.remove() }
        suite.makeDefaults().set("kept", forKey: "value")
        await waitUntil("the suite plist is written", timeout: 10) {
            FileManager.default.fileExists(atPath: suite.name + ".plist")
        }

        suite.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.directory.path))
        XCTAssertNil(suite.makeDefaults().string(forKey: "value"))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: suite.directory.path),
            "reading a removed suite recreated its directory"
        )
    }

    func testTeardownRemovesTheSuite() {
        let directory = OSAllocatedUnfairLock<URL?>(initialState: nil)
        // Teardown blocks run last in, first out, so this one runs after the
        // suite's own removal.
        addTeardownBlock {
            guard let directory = directory.withLock({ $0 }) else {
                XCTFail("the test never created its suite")
                return
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        let suite = makeTemporaryDefaultsSuite()
        directory.withLock { $0 = suite.directory }
        suite.makeDefaults().set("kept", forKey: "value")
        XCTAssertTrue(FileManager.default.fileExists(atPath: suite.directory.path))
    }
}
