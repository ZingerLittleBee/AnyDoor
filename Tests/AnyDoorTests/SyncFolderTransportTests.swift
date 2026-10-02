import Foundation
import os
import XCTest
@testable import AnyDoor

/// A file call that blocks the way one into a hung mount does: it returns only
/// after `release()`. Shared with `SyncEngineTests`.
final class StalledFileCall: Sendable {
    private struct Counts {
        var entries = 0
        var finished = 0
    }

    private let counts = OSAllocatedUnfairLock(initialState: Counts())
    private let gate = DispatchSemaphore(value: 0)

    /// A stalled call that `testCase` releases at teardown, so no blocked
    /// thread outlives the test.
    static func releasedAtTeardown(of testCase: XCTestCase) -> StalledFileCall {
        let call = StalledFileCall()
        testCase.addTeardownBlock { call.release() }
        return call
    }

    /// Calls that entered `block()`.
    var entries: Int { counts.withLock { $0.entries } }

    /// Whether any blocked call has returned.
    var didFinish: Bool { counts.withLock { $0.finished > 0 } }

    /// Blocks the calling thread until `release()`.
    func block() {
        counts.withLock { $0.entries += 1 }
        gate.wait()
        gate.signal() // Pass the release on to any other blocked call.
        counts.withLock { $0.finished += 1 }
    }

    /// Lets every blocked call return, and every later one pass straight
    /// through. Safe to call again.
    func release() {
        gate.signal()
    }
}

/// The folder transport against calls that hang the way a stalled mount or a
/// dataless cloud file does. Every wait is bounded, so a regression fails the
/// test instead of hanging it.
@MainActor
final class SyncFolderTransportTests: XCTestCase {

    private var folder: URL!

    override func setUp() async throws {
        // In-flight calls are tracked process-wide by path, so each test gets a
        // folder of its own.
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncFolderTransportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeTransport(
        timeout: TimeInterval,
        _ configure: (inout SyncFolderFileSystem) -> Void
    ) -> SyncFolderTransport {
        var fileSystem = SyncFolderFileSystem()
        configure(&fileSystem)
        return SyncFolderTransport(folderURL: folder, timeout: timeout, fileSystem: fileSystem)
    }

    private func writePeer(_ deviceID: String) throws {
        try SyncStateCodec.encode(SyncDocument(deviceID: deviceID)).write(
            to: folder.appendingPathComponent(SyncStateFile.name(forDeviceID: deviceID)),
            options: .atomic
        )
    }

    /// The error `operation` throws within `timeout`; nil, with a failure
    /// recorded, when it returns instead.
    private func thrownError<T: Sendable>(
        within timeout: TimeInterval = 5,
        cancelWhen shouldCancel: (@Sendable () -> Bool)? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> (any Error)? {
        do {
            _ = try await bounded(
                within: timeout, cancelWhen: shouldCancel, file: file, line: line, operation
            )
            XCTFail("expected an error", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    func testHungListingTimesOutWithoutWaitingForIt() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 0.2) { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }

        let error = await thrownError {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(error as? SyncTransportError, .timedOut)
        XCTAssertFalse(listing.didFinish, "the caller moved on while the listing still hangs")
    }

    func testStuckPathFailsAtOnceUntilItsCallReturns() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 0.2) { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }
        _ = await thrownError {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }

        // The listing has outlived its timeout, so it is known to be stuck: the
        // next call fails instead of stranding a second thread behind it.
        let error = await thrownError {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(error as? SyncTransportError, .timedOut)
        XCTAssertEqual(listing.entries, 1, "no second listing started behind the stuck one")

        listing.release()
        await waitUntil("the folder to list again once the stuck listing returns") {
            (try? await transport.readPeerDocuments(excludingDeviceID: "this-mac")) != nil
        }
    }

    /// Engine restarts build a new transport on the same folder. The stuck
    /// listing still fails the new transport at once, although the new
    /// transport's own timeout has not run out.
    func testStuckCallHoldsItsPathAcrossTransports() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let configure: (inout SyncFolderFileSystem) -> Void = { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }
        let first = makeTransport(timeout: 0.2, configure)
        _ = await thrownError {
            try await first.readPeerDocuments(excludingDeviceID: "this-mac")
        }

        let second = makeTransport(timeout: 30, configure)
        let error = await thrownError {
            try await second.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(error as? SyncTransportError, .timedOut)
        XCTAssertEqual(listing.entries, 1, "the second transport started no listing of its own")
    }

    /// A call that is slow but within its timeout is not stuck. A call on its
    /// path, such as a restarted engine's first tick, waits for it and then
    /// runs, instead of reporting a healthy folder as unreachable.
    func testCallWaitsForAHealthyCallOnItsPathThenRuns() async throws {
        try writePeer("peer-a")
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 30) { fileSystem in
            fileSystem.listFileNames = { folder in
                listing.block()
                return try FileManager.default.contentsOfDirectory(atPath: folder.path)
            }
        }

        let first = Task { try await transport.readPeerDocuments(excludingDeviceID: "this-mac") }
        await waitUntil("the first listing to start") { listing.entries == 1 }
        let second = Task { try await transport.readPeerDocuments(excludingDeviceID: "this-mac") }
        await waitUntil("the second call to wait for the path") {
            SyncFolderCalls.waitingCallCountForTesting(on: folder) == 1
        }
        XCTAssertEqual(listing.entries, 1, "the second call waits instead of listing alongside")

        listing.release()
        let firstPeers = try await bounded(within: 5) { try await first.value }
        let secondPeers = try await bounded(within: 5) { try await second.value }
        XCTAssertEqual(firstPeers.map(\.deviceID), ["peer-a"])
        XCTAssertEqual(secondPeers.map(\.deviceID), ["peer-a"])
        XCTAssertEqual(listing.entries, 2, "the second call listed once the first returned")
    }

    /// A call waiting behind a healthy call gives up at its own deadline when
    /// that call then hangs, instead of waiting for it for good.
    func testWaitingCallTimesOutAtItsOwnDeadline() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let configure: (inout SyncFolderFileSystem) -> Void = { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }
        let holder = makeTransport(timeout: 30, configure)
        let first = Task { try await holder.readPeerDocuments(excludingDeviceID: "this-mac") }
        addTeardownBlock { first.cancel() }
        await waitUntil("the first listing to start") { listing.entries == 1 }

        let waiting = makeTransport(timeout: 0.3, configure)
        let error = await thrownError {
            try await waiting.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(error as? SyncTransportError, .timedOut)
        XCTAssertEqual(listing.entries, 1, "the waiting call never listed")
        XCTAssertEqual(SyncFolderCalls.waitingCallCountForTesting(on: folder), 0, "the timed-out call stopped waiting")
    }

    func testCancellingAWaitingCallFreesItAtOnce() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 30) { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }
        let first = Task { try await transport.readPeerDocuments(excludingDeviceID: "this-mac") }
        addTeardownBlock { first.cancel() }
        await waitUntil("the first listing to start") { listing.entries == 1 }

        let folder = folder!
        let error = await thrownError(cancelWhen: {
            SyncFolderCalls.waitingCallCountForTesting(on: folder) == 1
        }) {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        XCTAssertEqual(listing.entries, 1, "the cancelled call never listed")
        XCTAssertEqual(SyncFolderCalls.waitingCallCountForTesting(on: folder), 0, "the cancelled call stopped waiting")
    }

    /// A call that waited before it claimed its path is stuck only once its
    /// claim, not its caller's wait, is older than its timeout. A restarted
    /// engine's next call waits for it instead of failing a healthy folder.
    func testCallThatClaimedLateIsNotStuckUntilItsClaimAges() async throws {
        let firstListing = StalledFileCall.releasedAtTeardown(of: self)
        let laterListings = StalledFileCall.releasedAtTeardown(of: self)
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let configure: (inout SyncFolderFileSystem) -> Void = { fileSystem in
            fileSystem.listFileNames = { _ in
                let index = listings.withLock { count -> Int in
                    defer { count += 1 }
                    return count
                }
                if index == 0 { firstListing.block() } else { laterListings.block() }
                return []
            }
        }
        let folder = folder!
        let oldEngine = makeTransport(timeout: 30, configure)
        let first = Task { try await oldEngine.readPeerDocuments(excludingDeviceID: "this-mac") }
        addTeardownBlock { first.cancel() }
        await waitUntil("the first listing to start") { firstListing.entries == 1 }

        let newEngine = makeTransport(timeout: 2, configure)
        let late = Task { try await newEngine.readPeerDocuments(excludingDeviceID: "this-mac") }
        await waitUntil("the second call to wait for the path") {
            SyncFolderCalls.waitingCallCountForTesting(on: folder) == 1
        }
        // The age under test: the second call spends 1 s of its 2 s waiting,
        // so its claim is 1 s younger than its caller's wait when that ends.
        try await Task.sleep(for: .seconds(1))
        firstListing.release()
        await waitUntil("the second call to claim the path and list") { laterListings.entries == 1 }
        let lateError = await thrownError { try await late.value }
        XCTAssertEqual(lateError as? SyncTransportError, .timedOut)

        // Its caller has given up, but its claim is only about 1 s old: the next
        // call waits for it instead of failing at once.
        let next = Task { try await newEngine.readPeerDocuments(excludingDeviceID: "this-mac") }
        await waitUntil("the next call to wait for the path") {
            SyncFolderCalls.waitingCallCountForTesting(on: folder) == 1
        }
        laterListings.release()
        _ = try await bounded(within: 5) { try await next.value }
        XCTAssertEqual(laterListings.entries, 2, "the next call listed once the late call returned")
    }

    func testStuckPeerFileIsSkippedWhileOtherFilesSync() async throws {
        try writePeer("peer-a")
        try writePeer("peer-b")
        let stuckRead = StalledFileCall.releasedAtTeardown(of: self)
        let stuckName = SyncStateFile.name(forDeviceID: "peer-b")
        // Only the stuck read pays the timeout; the healthy calls get headroom
        // on a loaded machine.
        let transport = makeTransport(timeout: 2) { fileSystem in
            fileSystem.read = { url in
                if url.lastPathComponent == stuckName { stuckRead.block() }
                return try Data(contentsOf: url)
            }
        }

        let peers = try await bounded(within: 5) {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(peers.map(\.deviceID), ["peer-a"])

        // A stuck path holds only itself: this Mac's own file still writes.
        try await bounded(within: 5) {
            try await transport.writeOwnDocument(Data("own".utf8), deviceID: "this-mac")
        }
        let ownFile = folder.appendingPathComponent(SyncStateFile.name(forDeviceID: "this-mac"))
        XCTAssertEqual(try Data(contentsOf: ownFile), Data("own".utf8))
    }

    func testHungWriteTimesOutAndALaterWriteLandsLast() async throws {
        let stuckWrite = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 0.2) { fileSystem in
            fileSystem.write = { data, url in
                stuckWrite.block()
                try data.write(to: url, options: .atomic)
            }
        }
        let staleData = Data("stale".utf8)
        let newData = Data("new".utf8)

        let error = await thrownError {
            try await transport.writeOwnDocument(staleData, deviceID: "this-mac")
        }
        XCTAssertEqual(error as? SyncTransportError, .timedOut)

        // While the stale write is stuck, a newer one fails instead of racing it.
        let secondError = await thrownError {
            try await transport.writeOwnDocument(newData, deviceID: "this-mac")
        }
        XCTAssertEqual(secondError as? SyncTransportError, .timedOut)
        XCTAssertEqual(stuckWrite.entries, 1, "no second write started behind the stuck one")

        stuckWrite.release()
        await waitUntil("a write to land once the stuck one returns") {
            (try? await transport.writeOwnDocument(newData, deviceID: "this-mac")) != nil
        }
        let ownFile = folder.appendingPathComponent(SyncStateFile.name(forDeviceID: "this-mac"))
        XCTAssertEqual(try Data(contentsOf: ownFile), newData, "the stale write landed after the newer one")
    }

    func testCancellationFreesTheCallerAtOnce() async throws {
        let listing = StalledFileCall.releasedAtTeardown(of: self)
        let transport = makeTransport(timeout: 30) { fileSystem in
            fileSystem.listFileNames = { _ in listing.block(); return [] }
        }

        let error = await thrownError(cancelWhen: { listing.entries == 1 }) {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        XCTAssertFalse(listing.didFinish, "the caller moved on while the listing still hangs")
    }

    func testCancelledCallerNeverStartsTheCall() async throws {
        let listings = OSAllocatedUnfairLock(initialState: 0)
        let transport = makeTransport(timeout: 5) { fileSystem in
            fileSystem.listFileNames = { _ in
                listings.withLock { $0 += 1 }
                return []
            }
        }

        // The task runs on the main actor, which this test holds until its next
        // await, so the task is cancelled before it starts.
        let call = Task { try await transport.readPeerDocuments(excludingDeviceID: "this-mac") }
        call.cancel()
        let error = await thrownError { try await call.value }
        XCTAssertTrue(error is CancellationError, "expected CancellationError, got \(String(describing: error))")
        XCTAssertEqual(listings.withLock { $0 }, 0)

        // It never claimed the folder either, so the next call lists it.
        _ = try await bounded(within: 5) {
            try await transport.readPeerDocuments(excludingDeviceID: "this-mac")
        }
        XCTAssertEqual(listings.withLock { $0 }, 1)
    }
}
