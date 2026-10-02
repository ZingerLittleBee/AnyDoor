import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryFixtureLifecycleTests: XCTestCase {
    func testTeardownDrainsEveryStoreAfterThrowingSetup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnyDoor-FixtureLifecycle-\(UUID().uuidString)")
        let observation = FixtureLifecycleObservation()
        let gate = FixtureVisionGate()

        // This runs last, after both module closes and directory cleanup.
        addTeardownBlock {
            let modules = await observation.snapshot()
            XCTAssertEqual(modules.count, 2)
            for module in modules {
                let database = await module.database
                XCTAssertNil(database)
            }
            let released = await gate.isReleased
            XCTAssertTrue(released)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
        removeClipboardHistoryDirectoryAfterTest(directory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            try await createStoresThenThrow(
                in: directory,
                observation: observation,
                gate: gate
            )
            XCTFail("Expected fixture setup to throw")
        } catch FixtureSetupError.interrupted {
            // No module or directory is manually cleaned up on this path.
        }
    }

    private func createStoresThenThrow(
        in directory: URL,
        observation: FixtureLifecycleObservation,
        gate: FixtureVisionGate
    ) async throws {
        let first = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: directory.appendingPathComponent("first.sqlite"),
            databaseKey: Data(repeating: 0xE1, count: 32)
        ))
        await observation.record(first)
        _ = try await first.capture(ClipboardHistoryCaptureRequest(
            source: .unknown,
            content: .text("fixture teardown")
        ))
        // A deliberate mid-test close must coexist with automatic teardown.
        try await first.closeStoreForTesting()

        let second = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: directory.appendingPathComponent("second.sqlite"),
            databaseKey: Data(repeating: 0xE2, count: 32),
            visionRecognizer: gate
        ), beforeClosing: { await gate.release() })
        await observation.record(second)
        let bitmapURL = try XCTUnwrap(Bundle.module.url(
            forResource: "representative-text",
            withExtension: "png"
        ))
        _ = try await second.capture(ClipboardHistoryCaptureRequest(
            source: .unknown,
            content: .bitmap(try Data(contentsOf: bitmapURL), provenance: .image)
        ))
        await gate.waitUntilStarted()
        throw FixtureSetupError.interrupted
    }
}

private enum FixtureSetupError: Error {
    case interrupted
}

private actor FixtureLifecycleObservation {
    private var modules: [ClipboardHistoryModule] = []

    func record(_ module: ClipboardHistoryModule) {
        modules.append(module)
    }

    func snapshot() -> [ClipboardHistoryModule] {
        modules
    }
}

private actor FixtureVisionGate: ClipboardHistoryVisionRecognizing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var isReleased = false

    func recognize(
        _ kind: ClipboardHistoryDerivedJobKind,
        in bitmaps: [Data]
    ) async throws -> [String] {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        if !isReleased {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return []
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
