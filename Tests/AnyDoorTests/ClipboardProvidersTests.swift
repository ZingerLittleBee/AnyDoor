import AppKit
import XCTest

@testable import AnyDoor

final class ClipboardProvidersTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ClipboardProvidersTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testMonitoringProviderReflectsAndTogglesClipboardPreference() async throws {
        let provider = ClipboardMonitoringProvider(defaults: defaults)

        let initial = try await provider.readState()
        XCTAssertTrue(initial)

        try await provider.setState(false)
        XCTAssertFalse(defaults.bool(forKey: ClipboardPreferences.monitoringKey))
        let disabled = try await provider.readState()
        XCTAssertFalse(disabled)

        try await provider.setState(true)
        XCTAssertTrue(defaults.bool(forKey: ClipboardPreferences.monitoringKey))
        let enabled = try await provider.readState()
        XCTAssertTrue(enabled)
    }

    @MainActor
    func testClearClipboardActionClearsPasteboardAndSuppressesWatcherCapture() {
        let name = NSPasteboard.Name("AnyDoorClearClipboard-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        pasteboard.setString("secret", forType: .string)

        let changeCount = ClipboardActions.clear(pasteboard)

        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(changeCount, pasteboard.changeCount)
    }
}
