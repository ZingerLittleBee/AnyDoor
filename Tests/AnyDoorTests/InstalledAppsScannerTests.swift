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
}
