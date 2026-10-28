import XCTest
import AppKit
import os
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

    /// A lookup can wait on LaunchServices indefinitely. A prewarm of more such
    /// paths than the machine has cores must still leave Swift's cooperative
    /// pool free, or no actor in the app can run (Clear Notifications did
    /// nothing until relaunch). Synchronous on purpose: XCTest's waiter spins
    /// the main run loop without needing a pool thread, so a starved pool
    /// fails this test instead of hanging it.
    func testBlockedLookupsLeaveTheConcurrencyPoolFree() {
        let lookupStarted = expectation(description: "a lookup started")
        let gate = LookupGate(firstEntry: lookupStarted)
        let originalResolve = AppIconCache.resolveIcon
        AppIconCache.resolveIcon = { _ in
            gate.wait()
            return NSImage()
        }
        defer {
            gate.open()
            AppIconCache.resolveIcon = originalResolve
        }

        let blockedCount = ProcessInfo.processInfo.activeProcessorCount * 2 + 2
        AppIconCache.prewarm((0..<blockedCount).map {
            "/private/var/anydoor-tests/blocked-lookup-\(UUID().uuidString)-\($0).app"
        })
        wait(for: [lookupStarted], timeout: 2)
        // Let every prewarm task start its lookup.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let actorRan = expectation(description: "an unrelated actor ran")
        Task.detached(priority: .userInitiated) {
            await PoolProbe().touch()
            actorRan.fulfill()
        }
        wait(for: [actorRan], timeout: 2)
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

/// Holds every `wait()` caller until `open()`, which is called once, and
/// fulfills `firstEntry` when the first caller arrives.
private final class LookupGate: Sendable {
    private let group = DispatchGroup()
    private let firstEntry: XCTestExpectation
    private let hasEntry = OSAllocatedUnfairLock(initialState: false)

    init(firstEntry: XCTestExpectation) {
        self.firstEntry = firstEntry
        group.enter()
    }

    func wait() {
        let isFirst = hasEntry.withLock { hasEntry in
            defer { hasEntry = true }
            return !hasEntry
        }
        if isFirst { firstEntry.fulfill() }
        group.wait()
    }

    func open() { group.leave() }
}

/// An actor unrelated to the icon cache; it runs only when the pool has a
/// thread for it.
private actor PoolProbe {
    func touch() {}
}
