import XCTest
@testable import AnyDoor

@MainActor
final class CaptureSettingsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "capture.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsWhenUnset() {
        let s = CaptureSettings(defaults: makeDefaults())
        XCTAssertEqual(s.namingTemplate, "Screenshot YYYY-MM-DD at HH.mm.ss")
        XCTAssertTrue(s.autoCopy)
        XCTAssertTrue(s.autoSave)
        XCTAssertEqual(s.delaySeconds, 5)
        XCTAssertEqual(s.overlayTimeout, 8)
    }

    func testSettersPersist() {
        let d = makeDefaults()
        let s = CaptureSettings(defaults: d)
        s.setAutoCopy(false)
        s.setDelaySeconds(10)
        let reloaded = CaptureSettings(defaults: d)
        XCTAssertFalse(reloaded.autoCopy)
        XCTAssertEqual(reloaded.delaySeconds, 10)
    }
}
