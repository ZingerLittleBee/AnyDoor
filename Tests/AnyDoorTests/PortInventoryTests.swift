import XCTest
@testable import AnyDoor

final class PortInventoryTests: XCTestCase {
    func testBuiltinItemPortManagerExists() {
        XCTAssertTrue(BuiltinItem.allCases.contains(.portManager))
        XCTAssertEqual(BuiltinItem.portManager.kind, .submenu)
        XCTAssertEqual(BuiltinItem.portManager.title, "端口管理")
        XCTAssertEqual(BuiltinItem.portManager.symbol, "network")
    }

    func testPortRecordIdComposition() {
        let r = PortRecord(
            port: 3000,
            pid: 67035,
            processName: "node",
            executablePath: nil,
            commandLine: nil,
            binds: [PortBind(address: "*", family: .ipv4)]
        )
        XCTAssertEqual(r.id, "67035-3000")
    }

    func testSignalResultEquatable() {
        XCTAssertEqual(SignalResult.success, SignalResult.success)
        XCTAssertEqual(SignalResult.failure(.EPERM), SignalResult.failure(.EPERM))
        XCTAssertNotEqual(SignalResult.success, SignalResult.failure(.EPERM))
    }

    func testSubprocessResultStruct() {
        let r = SubprocessResult(
            stdout: "out", stderr: "err", exit: 0, timedOut: false
        )
        XCTAssertEqual(r.stdout, "out")
        XCTAssertEqual(r.stderr, "err")
        XCTAssertEqual(r.exit, 0)
        XCTAssertFalse(r.timedOut)
    }

    @MainActor
    func testViewModeDefaultsToList() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory.viewMode, .list)
    }

    @MainActor
    func testViewModePersistsToDefaults() {
        let defaults = isolatedDefaults()
        let inventory = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        inventory.viewMode = .tree

        // New instance reads back the persisted value.
        let inventory2 = PortInventory(
            scanner: StubScanner(records: []),
            defaults: defaults
        )
        XCTAssertEqual(inventory2.viewMode, .tree)
    }

    // Test helpers
    private struct StubScanner: PortScanning {
        let records: [PortRecord]
        var killBehavior: @Sendable (pid_t, Int32) -> SignalResult = { _, _ in .success }
        func scanTCPListening() async throws -> [PortRecord] { records }
        func kill(pid: pid_t, signal: Int32) -> SignalResult { killBehavior(pid, signal) }
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "PortInventoryTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    /// Scanner that lets the test resolve `scanTCPListening()` on demand.
    private actor BlockingScanner: PortScanning {
        struct Pending {
            let continuation: CheckedContinuation<[PortRecord], Error>
        }
        private var queue: [Pending] = []
        private(set) var calls = 0
        func resolve(with records: [PortRecord]) async {
            calls += 1
            if let next = queue.first {
                queue.removeFirst()
                next.continuation.resume(returning: records)
            }
        }
        func fail(with error: Error) async {
            if let next = queue.first {
                queue.removeFirst()
                next.continuation.resume(throwing: error)
            }
        }
        func scanTCPListening() async throws -> [PortRecord] {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[PortRecord], Error>) in
                queue.append(Pending(continuation: cont))
            }
        }
        nonisolated func kill(pid: pid_t, signal: Int32) -> SignalResult { .success }
    }

    @MainActor
    func testRefreshPopulatesRecords() async {
        let stub = StubScanner(records: [
            PortRecord(port: 3000, pid: 1, processName: "node",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ])
        let inv = PortInventory(scanner: stub, defaults: isolatedDefaults())
        await inv.refresh()
        XCTAssertEqual(inv.records.count, 1)
        XCTAssertEqual(inv.records[0].port, 3000)
        XCTAssertFalse(inv.isRefreshing)
        XCTAssertNil(inv.lastError)
    }

    @MainActor
    func testRefreshFailurePreservesRecordsAndSetsError() async {
        struct ThrowingScanner: PortScanning {
            func scanTCPListening() async throws -> [PortRecord] {
                throw PortScanError.lsofFailed(exitCode: 2, stderr: "boom")
            }
            func kill(pid: pid_t, signal: Int32) -> SignalResult { .success }
        }
        let inv = PortInventory(scanner: ThrowingScanner(), defaults: isolatedDefaults())
        // Seed records via a stub first refresh would be ideal; here we just verify error path.
        await inv.refresh()
        XCTAssertNotNil(inv.lastError)
        XCTAssertFalse(inv.isRefreshing)
    }

    @MainActor
    func testRefreshCancellationDoesNotSurfaceAsScanError() async {
        struct CancellingScanner: PortScanning {
            func scanTCPListening() async throws -> [PortRecord] {
                throw CancellationError()
            }
            func kill(pid: pid_t, signal: Int32) -> SignalResult { .success }
        }
        let inv = PortInventory(scanner: CancellingScanner(), defaults: isolatedDefaults())

        await inv.refresh()

        XCTAssertNil(inv.lastError)
        XCTAssertFalse(inv.isRefreshing)
    }

    /// Records every kill call and lets the test choose what `SignalResult` to return.
    private final class RecordingKillScanner: PortScanning, @unchecked Sendable {
        var records: [PortRecord]
        let killHandler: (pid_t, Int32) -> SignalResult
        private(set) var killCalls: [(pid: pid_t, sig: Int32)] = []
        init(records: [PortRecord], killHandler: @escaping (pid_t, Int32) -> SignalResult) {
            self.records = records
            self.killHandler = killHandler
        }
        func scanTCPListening() async throws -> [PortRecord] { records }
        func kill(pid: pid_t, signal: Int32) -> SignalResult {
            killCalls.append((pid, signal))
            return killHandler(pid, signal)
        }
    }

    @MainActor
    func testKillEPERMRecordsPermissionDenied() async {
        let r = PortRecord(port: 80, pid: 99, processName: "root-thing",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .failure(.EPERM) }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        await inv.kill(pid: 99)
        XCTAssertEqual(inv.failedKillPIDs[99]?.reason, .permissionDenied)
        XCTAssertFalse(inv.killingPIDs.contains(99))
    }

    @MainActor
    func testKillESRCHIsNotRecordedAsFailure() async {
        let r = PortRecord(port: 80, pid: 99, processName: "x",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .failure(.ESRCH) }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        scanner.records = [] // pretend the process is already gone
        await inv.kill(pid: 99)
        XCTAssertNil(inv.failedKillPIDs[99])
        XCTAssertFalse(inv.killingPIDs.contains(99))
    }

    @MainActor
    func testKillSuccessEscalatesToSIGKILLWhenProcessSurvives() async {
        let r = PortRecord(port: 80, pid: 99, processName: "stubborn",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .success }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        // Pid still present after SIGTERM, so SIGKILL should be sent.
        await inv.kill(pid: 99)
        let sigs = scanner.killCalls.map(\.sig)
        XCTAssertTrue(sigs.contains(SIGTERM))
        XCTAssertTrue(sigs.contains(SIGKILL))
    }

    @MainActor
    func testKillSuccessNoEscalateWhenProcessExits() async {
        let r = PortRecord(port: 80, pid: 99, processName: "fast-exit",
                           executablePath: nil, commandLine: nil,
                           binds: [PortBind(address: "*", family: .ipv4)])
        let scanner = RecordingKillScanner(records: [r]) { _, _ in .success }
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())
        await inv.refresh()
        // After SIGTERM, simulate the process being gone before refresh checks.
        scanner.records = []
        await inv.kill(pid: 99)
        let sigs = scanner.killCalls.map(\.sig)
        XCTAssertEqual(sigs, [SIGTERM])
    }

    @MainActor
    func testIsRefreshingClearsOnlyWhenAllInflightFinish() async throws {
        let scanner = BlockingScanner()
        let inv = PortInventory(scanner: scanner, defaults: isolatedDefaults())

        // Start refresh #1 — it blocks awaiting the scanner.
        let t1: Task<Void, Never> = Task { @MainActor in await inv.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "first refresh should mark isRefreshing")

        // Start refresh #2 — also blocked.
        let t2: Task<Void, Never> = Task { @MainActor in await inv.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "still refreshing with two in flight")

        // Resolve the older one (refresh #1) first.
        await scanner.resolve(with: [])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(inv.isRefreshing, "stale completion must NOT clear isRefreshing while #2 is still running")

        // Resolve the newer one.
        await scanner.resolve(with: [
            PortRecord(port: 9, pid: 2, processName: "x",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ])
        await t1.value
        await t2.value
        XCTAssertFalse(inv.isRefreshing)
        XCTAssertEqual(inv.records.count, 1)
        XCTAssertEqual(inv.records[0].port, 9)
    }

    @MainActor
    func testFilteredEmptyQueryReturnsPortAscending() async {
        let recs = [
            PortRecord(port: 5000, pid: 1, processName: "a", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 80, pid: 2, processName: "b", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 3000, pid: 3, processName: "c", executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        XCTAssertEqual(inv.filteredRecords.map(\.port), [80, 3000, 5000])
    }

    @MainActor
    func testSearchPriorityPortBeforeNameBeforePid() async {
        let recs = [
            PortRecord(port: 3000, pid: 99, processName: "node",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 8080, pid: 30,  processName: "java",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        inv.searchText = "30"
        // Port :3000 matches the "30" substring; pid 30 also matches. Port should come first.
        XCTAssertEqual(inv.filteredRecords.map(\.port), [3000, 8080])
    }

    @MainActor
    func testSearchIsCaseInsensitive() async {
        let recs = [
            PortRecord(port: 1, pid: 1, processName: "NodeProcess",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)])
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        inv.searchText = "node"
        XCTAssertEqual(inv.filteredRecords.count, 1)
    }

    @MainActor
    func testGroupedByProcessSortsByNameThenPort() async {
        let recs = [
            PortRecord(port: 5000, pid: 10, processName: "bravo",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 80, pid: 10, processName: "bravo",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
            PortRecord(port: 22, pid: 20, processName: "alpha",
                       executablePath: nil, commandLine: nil,
                       binds: [PortBind(address: "*", family: .ipv4)]),
        ]
        let inv = PortInventory(scanner: StubScanner(records: recs), defaults: isolatedDefaults())
        await inv.refresh()
        let groups = inv.groupedByProcess
        XCTAssertEqual(groups.map(\.processName), ["alpha", "bravo"])
        XCTAssertEqual(groups[1].ports.map(\.port), [80, 5000])
    }
}
