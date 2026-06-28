import XCTest
@testable import AnyDoor

@MainActor
final class InstalledAppsScannerTests: XCTestCase {
    func testScanFindsFinder() {
        let apps = InstalledAppsScanner.scan()
        let finder = apps.first { $0.bundleID == "com.apple.finder" }
        XCTAssertNotNil(finder, "Scanner must surface Finder so users can bind it to a shortcut")
        XCTAssertEqual(finder?.path, "/System/Library/CoreServices/Finder.app")
        XCTAssertTrue(finder?.isSystemApp ?? false)
    }

    func testScanResultsAreUniqueByBundleID() {
        let apps = InstalledAppsScanner.scan()
        let ids = apps.map(\.bundleID)
        XCTAssertEqual(ids.count, Set(ids).count, "Bundle IDs must be unique")
    }

    func testScanResultsAreSortedCaseInsensitively() {
        let apps = InstalledAppsScanner.scan()
        let names = apps.map(\.displayName)
        let sorted = names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(names, sorted)
    }

    // MARK: - Bounded recursion / symlink resolution

    func testScanFindsTopLevelApp() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeAppBundle(in: root, named: "TopLevel.app", bundleID: "test.top")

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        XCTAssertTrue(apps.contains { $0.bundleID == "test.top" })
    }

    func testScanFindsAppNestedOneLevelDeep() throws {
        // Mirrors Setapp/*.app and "Adobe Photoshop 2026/Adobe Photoshop 2026.app".
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("VendorFolder")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try makeAppBundle(in: vendor, named: "Nested App.app", bundleID: "test.nested")

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        let nested = apps.first { $0.bundleID == "test.nested" }
        XCTAssertNotNil(nested, "Apps one folder deep (Setapp/Adobe style) must be found")
        XCTAssertEqual(nested?.displayName, "Nested App")
    }

    func testScanResolvesSymlinkWithoutAppSuffixAndKeepsLinkName() throws {
        // Mirrors "Adobe Creative Cloud/Adobe Creative Cloud" -> .../Creative Cloud.app.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // The real bundle lives outside the scanned root (mirrors Adobe's real
        // app sitting under Utilities, deeper than maxDepth), so only the
        // symlink can surface it.
        let realHome = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: realHome) }
        let realApp = try makeAppBundle(in: realHome, named: "Creative Cloud.app", bundleID: "test.cc")

        let vendor = root.appendingPathComponent("Adobe Creative Cloud")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let link = vendor.appendingPathComponent("Adobe Creative Cloud") // no .app suffix
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realApp)

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        let cc = apps.first { $0.bundleID == "test.cc" }
        XCTAssertNotNil(cc, "Symlink without a .app suffix must still resolve to its bundle")
        XCTAssertEqual(cc?.displayName, "Adobe Creative Cloud", "Should keep the user-facing link name")
    }

    func testScanDoesNotDescendIntoBundles() throws {
        // A bundle nested inside another bundle's payload must be ignored.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeAppBundle(in: root, named: "Outer.app", bundleID: "test.outer")
        let payload = outer.appendingPathComponent("Contents/Resources")
        try makeAppBundle(in: payload, named: "Inner.app", bundleID: "test.inner")

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        XCTAssertTrue(apps.contains { $0.bundleID == "test.outer" })
        XCTAssertFalse(apps.contains { $0.bundleID == "test.inner" }, "Must not walk into .app bundles")
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeAppBundle(in dir: URL, named name: String, bundleID: String) throws -> URL {
        let appURL = dir.appendingPathComponent(name)
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": appURL.deletingPathExtension().lastPathComponent,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return appURL
    }
}
