import AppIdentity
import XCTest

final class AppIdentityTests: XCTestCase {
    func testDevelopmentIdentityDoesNotShareProductionNamespace() {
        let development = AppIdentity(bundleIdentifier: "dev.bybee.AnyDoor.Dev")
        XCTAssertEqual(development.bundleIdentifier, "dev.bybee.AnyDoor.Dev")
        XCTAssertEqual(development.displayName, "AnyDoor Dev")

        // SwiftPM and the daily app must retain their existing store and
        // Keychain namespace, rather than follow arbitrary runner bundle IDs.
        for bundleID in [nil, "dev.bybee.AnyDoor", "org.swift.swiftpm.test-runner"] as [String?] {
            let identity = AppIdentity(bundleIdentifier: bundleID)
            XCTAssertEqual(identity.bundleIdentifier, "dev.bybee.AnyDoor")
            XCTAssertEqual(identity.displayName, "AnyDoor")
            XCTAssertNotEqual(identity.bundleIdentifier, development.bundleIdentifier)
        }
    }
}
