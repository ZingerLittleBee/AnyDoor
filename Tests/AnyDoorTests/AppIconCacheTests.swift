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

    /// NSWorkspace hands back a lazy image that renders through IconServices
    /// at its first draw size. The cache must do that draw off the main
    /// thread, under the app's appearance, and hand rows a Retina bitmap that
    /// never calls back into the lazy source, or the render lands on the main
    /// thread during the first scroll.
    func testIconsAreDrawnOffTheMainThreadIntoRetinaBitmaps() async throws {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        let originalResolve = AppIconCache.resolveIcon
        let draws = DrawRecorder()
        app.appearance = NSAppearance(named: .darkAqua)
        AppIconCache.resolveIcon = { _ in
            NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
                draws.record(onMainThread: Thread.isMainThread, appearance: NSAppearance.currentDrawing().name)
                NSColor.systemRed.setFill()
                rect.fill()
                return true
            }
        }
        defer {
            AppIconCache.resolveIcon = originalResolve
            app.appearance = originalAppearance
        }

        let icon = await AppIconCache.icon(for: "/private/var/anydoor-tests/drawn-\(UUID().uuidString).app")
        let resolveDraws = draws.all
        XCTAssertFalse(resolveDraws.isEmpty, "The lazy icon should be drawn while resolving")
        XCTAssertFalse(resolveDraws.contains { $0.onMainThread }, "The lazy icon must not be drawn on the main thread")
        XCTAssertEqual(resolveDraws.map(\.appearance), resolveDraws.map { _ in .darkAqua }, "The icon should be drawn under the app's appearance")

        let rep = try XCTUnwrap(icon.representations.first)
        XCTAssertEqual(icon.representations.count, 1, "The cached icon should be a single bitmap")
        XCTAssertTrue(rep is NSBitmapImageRep, "Expected a bitmap rep, got \(type(of: rep))")
        XCTAssertEqual(rep.pixelsWide, Int(icon.size.width * 2), "The bitmap should be rendered for Retina")

        // Drawing the cached icon, as a row does, must not reach the lazy source.
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 52, height: 52, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: 26, height: 26))
        NSGraphicsContext.restoreGraphicsState()
        XCTAssertEqual(draws.all.count, resolveDraws.count, "Drawing the cached icon must not redraw the lazy source")
    }

    /// App icons have Dark Mode variants, so an icon rendered under one
    /// appearance must never be served under another.
    func testIconsAreCachedPerAppearance() async {
        let app = NSApplication.shared
        let originalAppearance = app.appearance
        defer { app.appearance = originalAppearance }

        app.appearance = NSAppearance(named: .aqua)
        let light = await AppIconCache.icon(for: finderPath)
        app.appearance = NSAppearance(named: .darkAqua)
        XCTAssertFalse(AppIconCache.cached(finderPath) === light, "A light icon must not be served in Dark Mode")
        let dark = await AppIconCache.icon(for: finderPath)
        XCTAssertFalse(light === dark)

        app.appearance = NSAppearance(named: .aqua)
        XCTAssertTrue(AppIconCache.cached(finderPath) === light, "Switching back should reuse the light icon")
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

/// Records each draw of a test icon, from whichever thread draws it.
private final class DrawRecorder: Sendable {
    struct Draw: Sendable {
        let onMainThread: Bool
        let appearance: NSAppearance.Name
    }

    private let draws = OSAllocatedUnfairLock<[Draw]>(initialState: [])

    var all: [Draw] { draws.withLock { $0 } }

    func record(onMainThread: Bool, appearance: NSAppearance.Name) {
        draws.withLock { $0.append(Draw(onMainThread: onMainThread, appearance: appearance)) }
    }
}

/// An actor unrelated to the icon cache; it runs only when the pool has a
/// thread for it.
private actor PoolProbe {
    func touch() {}
}
