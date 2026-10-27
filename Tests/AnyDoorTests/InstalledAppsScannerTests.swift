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

    func testScanFindsCompanionAppsEmbeddedInHostBundleButNotAgents() throws {
        // Mirrors Xcode.app/Contents/Applications/DeviceHub.app and older
        // Xcode's Contents/Developer/Applications/Simulator.app, beside agents
        // such as Google Drive.app/Contents/Applications/FinderHelper.app.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = try makeAppBundle(in: root, named: "Host.app", bundleID: "test.host")
        let companions = host.appendingPathComponent("Contents/Applications")
        try makeAppBundle(in: companions, named: "Companion.app", bundleID: "test.companion")
        try makeAppBundle(
            in: companions, named: "Helper.app", bundleID: "test.helper",
            extraInfo: ["LSUIElement": true]
        )
        try makeAppBundle(
            in: companions, named: "Daemon.app", bundleID: "test.daemon",
            extraInfo: ["LSBackgroundOnly": "1"]
        )
        try makeAppBundle(
            in: host.appendingPathComponent("Contents/Developer/Applications"),
            named: "Simulator.app", bundleID: "test.simulator"
        )
        // A top-level menu-bar app is an agent too, but people launch it.
        try makeAppBundle(
            in: root, named: "MenuBar.app", bundleID: "test.menubar",
            extraInfo: ["LSUIElement": true]
        )

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        let ids = Set(apps.map(\.bundleID))
        XCTAssertEqual(ids, ["test.host", "test.companion", "test.simulator", "test.menubar"])
        XCTAssertEqual(
            apps.first { $0.bundleID == "test.companion" }?.path,
            companions.appendingPathComponent("Companion.app").path
        )
    }

    func testScanUsesLocalizedDisplayNameNotUnlocalizedInfoPlist() throws {
        // Info.plist stores an internal bundle name; every InfoPlist.strings
        // file stores a localized display name. Searching the localized name
        // in the palette only works if the scanner surfaces it.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeAppBundle(
            in: root,
            named: "InternalName-macOS.app",
            bundleID: "com.example.internal",
            unlocalizedDisplayName: "InternalName-macOS",
            localizedDisplayName: "示例应用"
        )

        let apps = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        let app = apps.first { $0.bundleID == "com.example.internal" }
        XCTAssertEqual(app?.displayName, "示例应用")
        XCTAssertEqual(app?.searchAliases, ["InternalName-macOS"])
    }

    // MARK: - Recorded app location

    func testLocateFollowsAppReinstalledUnderNewName() throws {
        // An app shortcut recorded "T3 Code (Nightly).app"; the user replaced it
        // with "T3 Code (Beta).app", which keeps the bundle identifier.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let beta = try makeAppBundle(in: root, named: "T3 Code (Beta).app", bundleID: "com.t3tools.t3code")
        let installed = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])

        let location = InstalledAppsScanner.locate(
            bundleID: "com.t3tools.t3code",
            recordedPath: root.appendingPathComponent("T3 Code (Nightly).app").path,
            in: installed
        )

        guard case .moved(let app) = location else {
            return XCTFail("Expected the reinstalled copy, got \(location)")
        }
        XCTAssertEqual(app.path, beta.path)
        XCTAssertEqual(app.displayName, "T3 Code (Beta)")
    }

    func testLocateKeepsRecordedCopyWhenScanDedupedToAnother() throws {
        // Xcode and Xcode-beta share a bundle identifier, so the scan lists only
        // one. A shortcut bound to the other copy must not be re-pointed.
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeAppBundle(in: root, named: "Xcode.app", bundleID: "com.apple.dt.Xcode")
        let second = try makeAppBundle(in: root, named: "Xcode-beta.app", bundleID: "com.apple.dt.Xcode")
        let installed = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])
        let scannedPath = try XCTUnwrap(installed.first { $0.bundleID == "com.apple.dt.Xcode" }?.path)
        let otherCopy = scannedPath == first.path ? second.path : first.path

        XCTAssertEqual(
            InstalledAppsScanner.locate(bundleID: "com.apple.dt.Xcode", recordedPath: otherCopy, in: installed),
            .unchanged
        )
    }

    func testLocateReportsUninstalledApp() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try makeAppBundle(in: root, named: "Other.app", bundleID: "test.other")
        let installed = InstalledAppsScanner.scan(roots: [root.path], extraAppPaths: [])

        XCTAssertEqual(
            InstalledAppsScanner.locate(
                bundleID: "test.gone",
                recordedPath: root.appendingPathComponent("Gone.app").path,
                in: installed
            ),
            .missing
        )
    }

    // MARK: - Helpers

    private func makeTempRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scanner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeAppBundle(
        in dir: URL,
        named name: String,
        bundleID: String,
        unlocalizedDisplayName: String? = nil,
        localizedDisplayName: String? = nil,
        extraInfo: [String: Any] = [:]
    ) throws -> URL {
        let appURL = dir.appendingPathComponent(name)
        let contents = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let fallbackName = appURL.deletingPathExtension().lastPathComponent
        var info: [String: Any] = extraInfo.merging([
            "CFBundleIdentifier": bundleID,
            "CFBundleName": unlocalizedDisplayName ?? fallbackName,
            "CFBundleDevelopmentRegion": "en",
        ]) { _, required in required }
        if let unlocalizedDisplayName {
            info["CFBundleDisplayName"] = unlocalizedDisplayName
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        if let localizedDisplayName {
            // Write the same localized name into every lproj so the assertion
            // does not depend on the test process's preferred languages. Some
            // shipped apps put that localized name in en/zh-Hans/Base alike.
            let strings: [String: String] = [
                "CFBundleDisplayName": localizedDisplayName,
                "CFBundleName": localizedDisplayName,
            ]
            let stringsData = try PropertyListSerialization.data(
                fromPropertyList: strings, format: .binary, options: 0
            )
            for lproj in ["Base.lproj", "en.lproj", "zh-Hans.lproj"] {
                let dir = contents.appendingPathComponent("Resources/\(lproj)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try stringsData.write(to: dir.appendingPathComponent("InfoPlist.strings"))
            }
        }
        return appURL
    }
}
