import XCTest
import CoreGraphics
@testable import AnyDoor

@MainActor
final class DisplayBrightnessServiceTests: XCTestCase {
    func testSetBrightnessUpdatesLevelsImmediately() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setBrightness(0.42, for: displayID)
        XCTAssertEqual(service.levels[displayID], 0.42)
    }

    func testSetBrightnessDebouncesWrites() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setBrightness(0.1, for: displayID)
        service.setBrightness(0.2, for: displayID)
        service.setBrightness(0.3, for: displayID)
        // wait for debounce window (30 ms) + execution slack
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(backend.writeCalls.count, 1, "expected one consolidated write")
        XCTAssertEqual(backend.writeCalls.last?.value, 30) // 0.3 * 100
    }

    func testBumpUsesFallbackBaselineWhenNil() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        // levels[displayID] starts nil → bump uses 0.5 + 0.0625 = 0.5625
        service.bumpForTesting(+0.0625, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 0.5625, accuracy: 0.001)
    }

    func testBumpClampsToZeroOne() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        service.setLevelForTesting(0.95, for: displayID)
        service.bumpForTesting(+0.5, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 1.0, accuracy: 0.001)

        service.setLevelForTesting(0.05, for: displayID)
        service.bumpForTesting(-0.5, displayID: displayID)
        XCTAssertEqual(service.levels[displayID]!, 0.0, accuracy: 0.001)
    }

    func testGenerationTokenInvalidatesBackfill() async throws {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: 80])  // real device value
        let controller = BrightnessController(backend: backend)
        let service = DisplayBrightnessService()
        service.bootstrap(controller: controller)
        service.injectDisplaysForTesting([
            DisplayInfo(id: displayID, name: "Test", supportsDDC: true)
        ])

        // levels[id] nil → triggers backfill after write
        service.bumpForTesting(+0.0625, displayID: displayID)
        let immediate = service.levels[displayID]
        XCTAssertEqual(immediate!, 0.5625, accuracy: 0.001)

        // Before backfill completes, user nudges again → generation bumps,
        // backfill must not clobber.
        service.bumpForTesting(+0.0625, displayID: displayID)
        let post = service.levels[displayID]
        XCTAssertEqual(post!, 0.625, accuracy: 0.001)

        // Give the backfill ample time to (incorrectly) overwrite.
        try await Task.sleep(nanoseconds: 200_000_000)

        // Generation guard wins → still 0.625, NOT 0.8 (backfill discarded).
        XCTAssertEqual(service.levels[displayID]!, 0.625, accuracy: 0.001)
    }
}
