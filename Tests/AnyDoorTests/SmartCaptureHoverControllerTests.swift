import Clocks
import CoreGraphics
import XCTest
@testable import AnyDoor

@MainActor
final class SmartCaptureHoverControllerTests: XCTestCase {
    private let screen = CGRect(x: -1_280, y: -200, width: 1_280, height: 800)
    private let firstPoint = CGPoint(x: -900, y: 100)
    private let secondPoint = CGPoint(x: -800, y: 150)
    private let lastPoint = CGPoint(x: -700, y: 200)

    func testRapidMovesCoalesceWithoutRestartingTheFirstDeadline() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .milliseconds(30))
        controller.request(at: secondPoint, screenFrame: screen, windows: [])
        controller.request(at: lastPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval - .milliseconds(31))
        XCTAssertTrue(resolver.requests.isEmpty)

        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(resolver.requests.map(\.point), [lastPoint])
        XCTAssertEqual(resolver.requests.first?.screenFrame, screen)
        XCTAssertEqual(resolver.maximumConcurrentCalls, 1)
        try await clock.checkSuspension()
    }

    func testPointerChangeRejectsSlowResultBeforeTheNextLookupStarts() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = { delivered.append($0) }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval)
        controller.request(at: secondPoint, screenFrame: screen, windows: [])
        try resolver.finishCall(at: 0, with: result(for: firstPoint))
        await clock.advance()

        XCTAssertTrue(delivered.isEmpty, "A pointer move invalidates the result immediately")
        XCTAssertEqual(resolver.requests.count, 1)
        await clock.advance(by: interval - .milliseconds(1))
        XCTAssertEqual(resolver.requests.count, 1)
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(resolver.requests.map(\.point), [firstPoint, secondPoint])
        XCTAssertTrue(delivered.isEmpty)

        let freshResult = result(for: secondPoint)
        try resolver.finishCall(at: 1, with: freshResult)
        await clock.advance()
        XCTAssertEqual(delivered, [freshResult])
        try await clock.checkSuspension()
    }

    func testMovesDuringResolutionKeepOnlyLatestAndNeverOverlap() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval)
        for x in 0..<500 {
            controller.request(at: CGPoint(x: x, y: 100), screenFrame: screen, windows: [])
        }
        controller.request(at: lastPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .seconds(5))
        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertEqual(resolver.maximumConcurrentCalls, 1)
        try await clock.checkSuspension()

        try resolver.finishCall(at: 0, with: result(for: firstPoint))
        await clock.advance(by: interval)
        XCTAssertEqual(resolver.requests.map(\.point), [firstPoint, lastPoint])
        XCTAssertEqual(resolver.maximumConcurrentCalls, 1)
    }

    func testIdenticalRequestDoesNotInvalidateOrRepublishHierarchy() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = { delivered.append($0) }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval)
        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        let resolution = result(for: firstPoint)
        try resolver.finishCall(at: 0, with: resolution)
        await clock.advance()
        XCTAssertEqual(delivered, [resolution], "An unchanged pointer must not invalidate an in-flight lookup")

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(resolver.requests.count, 1)
        XCTAssertEqual(delivered, [resolution], "Repeated events must preserve the user's Tab selection")
        try await clock.checkSuspension()
    }

    func testCancelBeforeDeadlinePreventsAnyLookupAndCanRestartAtSamePoint() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = { delivered.append($0) }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .milliseconds(20))
        controller.cancel()
        await clock.advance(by: .seconds(1))
        XCTAssertTrue(resolver.requests.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        try await clock.checkSuspension()

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval)
        XCTAssertEqual(resolver.requests.map(\.point), [firstPoint])
        let resolution = result(for: firstPoint)
        try resolver.finishCall(at: 0, with: resolution)
        await clock.advance()
        XCTAssertEqual(delivered, [resolution])
    }

    func testCancelDiscardsPendingAndEventualUncooperativeResult() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = { delivered.append($0) }

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: SmartCaptureHoverController.defaultThrottleInterval)
        controller.request(at: secondPoint, screenFrame: screen, windows: [])
        controller.cancel()
        // The fake deliberately ignores task cancellation, just as a blocking
        // Accessibility call may not return until its messaging timeout.
        try resolver.finishCall(at: 0, with: result(for: firstPoint))
        await clock.advance(by: .seconds(1))

        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(resolver.requests.map(\.point), [firstPoint])
        try await clock.checkSuspension()
    }

    func testImmediateRestartWaitsForCancelledResolutionAndUsesLatestRequest() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = { delivered.append($0) }
        let interval = SmartCaptureHoverController.defaultThrottleInterval

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        await clock.advance(by: interval)
        controller.cancel()
        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        controller.request(at: secondPoint, screenFrame: screen, windows: [])
        controller.request(at: lastPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .seconds(1))
        XCTAssertEqual(resolver.requests.count, 1, "Cancellation must not free the in-flight slot early")

        try resolver.finishCall(at: 0, with: result(for: firstPoint))
        await clock.advance(by: interval)
        XCTAssertEqual(resolver.requests.map(\.point), [firstPoint, lastPoint])
        XCTAssertEqual(resolver.maximumConcurrentCalls, 1)
        XCTAssertTrue(delivered.isEmpty)
        let freshResult = result(for: lastPoint)
        try resolver.finishCall(at: 1, with: freshResult)
        await clock.advance()
        XCTAssertEqual(delivered, [freshResult])
    }

    func testCancelledTimerCannotDisarmImmediateRestart() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(resolver: resolver, clock: clock)
        defer { controller.cancel(); resolver.finishAll() }

        controller.request(at: firstPoint, screenFrame: screen, windows: [])
        controller.cancel()
        controller.request(at: secondPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .milliseconds(30))
        controller.request(at: lastPoint, screenFrame: screen, windows: [])
        await clock.advance(by: .milliseconds(30))

        XCTAssertEqual(resolver.requests.map(\.point), [lastPoint])
        XCTAssertEqual(resolver.maximumConcurrentCalls, 1)
    }

    func testInjectedThrottleForwardsGeometryWindowsAndFallbackOnMainActor() async throws {
        let clock = TestClock()
        let resolver = ControlledSmartCaptureResolver()
        let controller = SmartCaptureHoverController(
            resolver: resolver, clock: clock, throttleInterval: .milliseconds(75)
        )
        defer { controller.cancel(); resolver.finishAll() }
        let windows = [CapturableWindow(id: 42, frame: screen)]
        let resolution = SmartCaptureResolution(
            targets: [SmartCaptureTarget(kind: .window(id: 42), globalFrame: screen)],
            fallbackReason: .accessibilityPermissionRequired
        )
        var delivered: [SmartCaptureResolution] = []
        controller.onResolution = {
            MainActor.assertIsolated()
            delivered.append($0)
        }

        controller.request(at: firstPoint, screenFrame: screen, windows: windows)
        await clock.advance(by: .milliseconds(74))
        XCTAssertTrue(resolver.requests.isEmpty)
        await clock.advance(by: .milliseconds(1))
        XCTAssertEqual(resolver.requests.first?.point, firstPoint)
        XCTAssertEqual(resolver.requests.first?.screenFrame, screen)
        XCTAssertEqual(resolver.requests.first?.windows, windows)
        try resolver.finishCall(at: 0, with: resolution)
        await clock.advance()
        XCTAssertEqual(delivered, [resolution])
        try await clock.checkSuspension()
    }

    private func result(for point: CGPoint) -> SmartCaptureResolution {
        SmartCaptureResolution(targets: [
            SmartCaptureTarget(
                kind: .accessibility(role: "AXButton"),
                globalFrame: CGRect(origin: point, size: CGSize(width: 80, height: 40))
            ),
        ])
    }
}

/// Main-actor isolation keeps the fake's mutable state safe while satisfying
/// the Sendable async resolver contract, without unchecked conformance or locks.
@MainActor
private final class ControlledSmartCaptureResolver: SmartCaptureTargetResolving {
    struct Request {
        let point: CGPoint
        let screenFrame: CGRect
        let windows: [CapturableWindow]
    }

    private(set) var requests: [Request] = []
    private(set) var maximumConcurrentCalls = 0
    private var continuations: [Int: CheckedContinuation<SmartCaptureResolution, Never>] = [:]

    func resolve(at point: CGPoint, screenFrame: CGRect, windows: [CapturableWindow]) async -> SmartCaptureResolution {
        let index = requests.count
        requests.append(Request(point: point, screenFrame: screenFrame, windows: windows))
        return await withCheckedContinuation { continuation in
            continuations[index] = continuation
            maximumConcurrentCalls = max(maximumConcurrentCalls, continuations.count)
        }
    }

    func finishCall(
        at index: Int,
        with resolution: SmartCaptureResolution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let continuation = try XCTUnwrap(continuations.removeValue(forKey: index), file: file, line: line)
        continuation.resume(returning: resolution)
    }

    func finishAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: SmartCaptureResolution(targets: []))
        }
    }
}
