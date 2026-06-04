import XCTest
import AppKit
@testable import AnyDoor

@MainActor
final class AppIconCacheTests: XCTestCase {
    private let finderPath = "/System/Library/CoreServices/Finder.app"

    func testCachedReturnsNilForUnrequestedPath() {
        // A path no other test resolves: the synchronous lookup must report a
        // miss without touching disk.
        XCTAssertNil(AppIconCache.cached("/private/var/anydoor-tests/never-requested.app"))
    }

    func testIconResolvesAndPopulatesCache() async {
        let icon = await AppIconCache.icon(for: finderPath)
        XCTAssertGreaterThan(icon.size.width, 0, "A resolved icon should have a real size")
        XCTAssertTrue(
            AppIconCache.cached(finderPath) === icon,
            "After resolving, the synchronous cache must return the same instance"
        )
    }

    func testRepeatResolutionReusesCachedInstance() async {
        let first = await AppIconCache.icon(for: finderPath)
        let second = await AppIconCache.icon(for: finderPath)
        XCTAssertTrue(first === second, "Repeated resolution must reuse the cached NSImage")
    }

    func testPrewarmPopulatesCacheOffMain() async {
        AppIconCache.prewarm([finderPath])
        // prewarm is fire-and-forget; poll the cache for the background result.
        let warmed = await waitForCachedIcon(finderPath)
        XCTAssertNotNil(warmed, "prewarm should resolve the icon into the cache")
    }

    /// Polls the synchronous cache until the icon appears or the timeout lapses.
    private func waitForCachedIcon(_ path: String, timeout: TimeInterval = 2) async -> NSImage? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let icon = AppIconCache.cached(path) { return icon }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        return AppIconCache.cached(path)
    }
}
