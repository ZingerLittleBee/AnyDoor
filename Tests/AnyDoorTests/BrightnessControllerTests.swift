import XCTest
import CoreGraphics
@testable import AnyDoor

final class BrightnessControllerTests: XCTestCase {
    func testProbeReturnsTrueWhenTransportReady() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID])
        let controller = BrightnessController(backend: backend)
        let result = await controller.probe(displayID: displayID)
        XCTAssertTrue(result)
    }

    func testProbeReturnsFalseWhenTransportMissing() async {
        let backend = MockDDCBackend(transportSupported: [])
        let controller = BrightnessController(backend: backend)
        let result = await controller.probe(displayID: 1)
        XCTAssertFalse(result)
    }

    func testReadNormalizesToZeroOne() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: 50])
        let controller = BrightnessController(backend: backend)
        let value = await controller.read(displayID: displayID)
        XCTAssertNotNil(value)
        XCTAssertEqual(value!, 0.5, accuracy: 0.01)
    }

    func testReadReturnsNilOnBackendNil() async {
        let displayID: CGDirectDisplayID = 1
        let backend = MockDDCBackend(transportSupported: [displayID],
                                     readResults: [displayID: nil])
        let controller = BrightnessController(backend: backend)
        let value = await controller.read(displayID: displayID)
        XCTAssertNil(value)
    }

    func testWriteRetriesOnceOnFailure() async {
        let displayID: CGDirectDisplayID = 1
        let backend = FlakyBackend(failuresBeforeSuccess: 1, supports: [displayID])
        let controller = BrightnessController(backend: backend)
        try? await controller.write(displayID: displayID, value: 0.75)
        XCTAssertEqual(backend.writeCount, 2)
    }

    func testWriteThrowsAfterTwoFailures() async {
        let displayID: CGDirectDisplayID = 1
        let backend = FlakyBackend(failuresBeforeSuccess: .max, supports: [displayID])
        let controller = BrightnessController(backend: backend)
        do {
            try await controller.write(displayID: displayID, value: 0.5)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(backend.writeCount, 2)
        }
    }

    /// The actor must serialise VCP I/O: even when many writes are fired
    /// concurrently (e.g. brightness-key autorepeat), no two backend
    /// transactions may be in flight at once, or interleaved DDC/CI exchanges
    /// corrupt each other on the same bus.
    func testConcurrentTransactionsDoNotOverlap() async {
        let displayID: CGDirectDisplayID = 1
        let backend = ConcurrencyProbeBackend(supports: [displayID])
        let controller = BrightnessController(backend: backend)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<8 {
                group.addTask {
                    try? await controller.write(displayID: displayID, value: Float(i) / 8.0)
                }
                group.addTask {
                    _ = await controller.read(displayID: displayID)
                }
            }
        }
        XCTAssertEqual(backend.maxInFlight, 1,
                       "DDC transactions must run one at a time; observed \(backend.maxInFlight) overlapping")
        XCTAssertEqual(backend.writeCount, 8)
    }
}

private final class FlakyBackend: DDCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let _supports: Set<CGDirectDisplayID>
    private(set) var writeCount = 0

    init(failuresBeforeSuccess: Int, supports: Set<CGDirectDisplayID>) {
        self.remainingFailures = failuresBeforeSuccess
        self._supports = supports
    }

    func transportReady(displayID: CGDirectDisplayID) -> Bool {
        _supports.contains(displayID)
    }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? { nil }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        let shouldFail: Bool = lock.withLock {
            writeCount += 1
            if remainingFailures > 0 {
                remainingFailures -= 1
                return true
            }
            return false
        }
        if shouldFail {
            throw NSError(domain: "flaky", code: 1)
        }
    }
}

/// Records the peak number of simultaneously in-flight backend transactions.
/// Each read/write holds an "in flight" slot across a short suspension so an
/// overlap is observable; with proper serialisation `maxInFlight` stays 1.
private final class ConcurrencyProbeBackend: DDCBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var writeCount = 0
    private let supports: Set<CGDirectDisplayID>

    init(supports: Set<CGDirectDisplayID>) { self.supports = supports }

    func transportReady(displayID: CGDirectDisplayID) -> Bool { supports.contains(displayID) }

    func read(displayID: CGDirectDisplayID, vcp: UInt8) async -> UInt16? {
        enter()
        defer { exit() }
        try? await Task.sleep(nanoseconds: 3_000_000)
        return 50
    }

    func write(displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) async throws {
        enter()
        defer { exit() }
        lock.withLock { writeCount += 1 }
        try? await Task.sleep(nanoseconds: 3_000_000)
    }

    private func enter() {
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
    }

    private func exit() {
        lock.withLock { inFlight -= 1 }
    }
}
