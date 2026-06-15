import XCTest
import CoreGraphics
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

    func testLastRegionRectRoundTrip() {
        let d = makeDefaults()
        let s = CaptureSettings(defaults: d)
        XCTAssertNil(s.lastRegionRect)
        s.setLastRegionRect(CGRect(x: -120.5, y: 40, width: 300, height: 200))
        let reloaded = CaptureSettings(defaults: d)
        XCTAssertEqual(reloaded.lastRegionRect, CGRect(x: -120.5, y: 40, width: 300, height: 200))
    }

    func testMalformedStoredValueDegradesToNil() {
        let d = makeDefaults()
        d.set([1.0, 2.0, 3.0], forKey: CaptureSettings.lastRegionRectKey) // wrong count
        XCTAssertNil(CaptureSettings(defaults: d).lastRegionRect)
        d.set([1.0, 2.0, Double.nan, 4.0], forKey: CaptureSettings.lastRegionRectKey) // non-finite
        XCTAssertNil(CaptureSettings(defaults: d).lastRegionRect)
    }
}
