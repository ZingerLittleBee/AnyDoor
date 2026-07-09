import AppKit
import XCTest
@testable import AnyDoor

final class BuiltinItemNewQuicklinkTests: XCTestCase {
    func testNewQuicklinkCaseExists() {
        XCTAssertNotNil(BuiltinItem(rawValue: "newQuicklink"))
        XCTAssertTrue(BuiltinItem.allCases.contains(.newQuicklink))
    }

    func testNewQuicklinkCatalogMetadata() {
        XCTAssertEqual(BuiltinItem.newQuicklink.kind, .action)
        XCTAssertEqual(BuiltinItem.newQuicklink.titleKey, .builtinNewQuicklink)
        XCTAssertEqual(BuiltinItem.newQuicklink.symbol, "link.badge.plus")
        XCTAssertEqual(BuiltinItem.newQuicklink.defaultOrder, 988)
        XCTAssertTrue(BuiltinItem.newQuicklink.defaultVisibility)
        XCTAssertFalse(BuiltinItem.newQuicklink.requiresAutomation)
    }

    func testNewQuicklinkStaysInGeneralCommandGroup() {
        XCTAssertEqual(BuiltinGroup.group(for: .newQuicklink), .general)
    }

    @MainActor
    func testNewQuicklinkProviderOpensQuicklinksSettingsTab() async throws {
        let opener = SettingsOpener.shared
        let previousOpen = opener.open
        let previousTab = opener.desiredTab
        defer {
            opener.open = previousOpen
            opener.desiredTab = previousTab
        }

        var didOpen = false
        opener.open = { didOpen = true }
        opener.desiredTab = nil
        _ = NSApplication.shared

        try await NewQuicklinkProvider().run()

        XCTAssertTrue(didOpen)
        XCTAssertEqual(opener.desiredTab, .quicklinks)
    }
}
