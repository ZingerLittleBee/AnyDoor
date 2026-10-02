import AppKit
import Darwin
import Foundation
import os
import XCTest
import ClipboardHistoryTestSupport

@testable import ClipboardHistory

/// Moving the store out of the pre-v2 `ClipboardHistory` folder, exercised
/// against real stores in temporary folders. Pre-v2 releases delete files
/// they do not recognize from that folder, which is how 4.2.x stores were
/// lost.
final class ClipboardHistoryStoreRelocationTests: XCTestCase {
    private let masterKey = Data(repeating: 0x42, count: 32)
    /// 2026-10-01T05:06:07Z; only names displaced stores.
    private let launchDate = Date(timeIntervalSince1970: 1_790_831_167)

    // MARK: - Layout

    func testStoreRootIsItsOwnFolderBesideThePreV2PayloadFolder() {
        let storeRoot = ClipboardHistoryModule.defaultStoreRoot
        let legacy = ClipboardHistoryModule.legacyPayloadDirectory
        XCTAssertEqual(storeRoot.lastPathComponent, "ClipboardHistoryV2")
        XCTAssertEqual(legacy.lastPathComponent, "ClipboardHistory")
        let parent = legacy.deletingLastPathComponent()
        XCTAssertEqual(parent.lastPathComponent, "dev.bybee.AnyDoor")
        XCTAssertEqual(
            storeRoot.deletingLastPathComponent().standardizedFileURL.path,
            parent.standardizedFileURL.path
        )
        XCTAssertEqual(
            ClipboardHistoryModule.legacyPayloadDirectory(in: parent)
                .standardizedFileURL.path,
            legacy.standardizedFileURL.path
        )
    }

    /// The frozen pre-v2 sweep deletes a store left in the legacy folder,
    /// which is what the move protects against.
    func testPreV2SweepDeletesAStoreLeftInTheLegacyFolder() async throws {
        let sandbox = try makeSandbox()
        try await makeStore(
            at: sandbox.legacy,
            keyStore: CountingKeyStore(key: masterKey),
            texts: ["secret"]
        )
        XCTAssertTrue(childNames(sandbox.legacy).contains("history.sqlite"))

        PreV2ClipboardHistorySweep.removeOrphanFiles(
            in: sandbox.legacy,
            keeping: []
        )

        XCTAssertEqual(childNames(sandbox.legacy), [])
    }

    // MARK: - Moving the store

    func testNoLegacyFolderIsANoOp() throws {
        let sandbox = try makeSandbox()

        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .nothingToRelocate
        )
        XCTAssertEqual(childNames(sandbox.root), [])
    }

    func testPreV2OnlyLegacyFolderIsLeftUntouched() throws {
        let sandbox = try makeSandbox()
        try FileManager.default.createDirectory(
            at: sandbox.legacy,
            withIntermediateDirectories: true
        )
        try Data("v1".utf8).write(
            to: sandbox.legacy.appendingPathComponent("\(UUID()).png")
        )
        let before = inventory(sandbox.legacy)

        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .nothingToRelocate
        )
        XCTAssertEqual(inventory(sandbox.legacy), before)
        XCTAssertEqual(childNames(sandbox.root), ["ClipboardHistory"])
    }

    func testMovesTheStoreWithItsWALAndReturnsPreV2Payloads() async throws {
        let layout = try await makeHeadLayout()

        XCTAssertEqual(
            try layout.sandbox.relocation().run(now: launchDate),
            .relocated
        )

        assertFinalLayout(layout)
        try await assertStoreOpens(
            at: layout.sandbox.target,
            keyStore: layout.keyStore,
            entries: layout.entryCount
        )
        XCTAssertEqual(
            try layout.sandbox.relocation().run(now: launchDate),
            .nothingToRelocate
        )
    }

    func testEveryInterruptionResumesToTheSameFinalState() async throws {
        let interruptions: [(ClipboardHistoryFaultPoint, Int)] = [
            (.storeRelocationAfterDetach, 1),
            (.storeRelocationAfterLeftoverReturned, 1),
            (.storeRelocationAfterLeftoverReturned, 2),
            (.storeRelocationBeforePublication, 1),
            (.storeRelocationAfterPublication, 1),
        ]
        for (point, occurrence) in interruptions {
            let label = "\(point) #\(occurrence)"
            let layout = try await makeHeadLayout()
            let sandbox = layout.sandbox

            XCTAssertThrowsError(
                try sandbox.relocation(
                    faults: failing(point, occurrence: occurrence)
                ).run(now: launchDate),
                label
            ) { error in
                XCTAssertEqual(
                    error as? ClipboardHistoryStorageError,
                    .injected(point),
                    label
                )
            }

            assertNothingLost(layout, label)
            // The store is never split: the main file, WAL and shared
            // memory sit together in exactly one folder at every point.
            let holders = [sandbox.legacy, sandbox.stagingRoot, sandbox.target]
                .filter {
                    exists($0.appendingPathComponent("history.sqlite"))
                }
            XCTAssertEqual(holders.count, 1, label)
            if let holder = holders.first {
                XCTAssertTrue(
                    exists(holder.appendingPathComponent("history.sqlite-wal")),
                    label
                )
            }

            XCTAssertEqual(
                try sandbox.relocation().run(now: launchDate),
                point == .storeRelocationAfterPublication
                    ? .nothingToRelocate : .relocated,
                label
            )
            assertFinalLayout(layout, label)
            try await assertStoreOpens(
                at: sandbox.target,
                keyStore: layout.keyStore,
                entries: layout.entryCount
            )
        }
    }

    /// A name taken in the legacy folder by the time a resumed move hands a
    /// file back (a pre-v2 release wrote it meanwhile) keeps both files.
    func testReturnedFileNeverReplacesOneWithTheSameName() async throws {
        let layout = try await makeHeadLayout()
        let sandbox = layout.sandbox
        XCTAssertThrowsError(
            try sandbox.relocation(
                faults: failing(.storeRelocationAfterLeftoverReturned)
            ).run(now: launchDate)
        )
        let name = try XCTUnwrap(
            childNames(sandbox.stagingRoot).first {
                !ClipboardHistoryStoreRelocation.storeArtifactNames
                    .contains($0)
            }
        )
        let original = try XCTUnwrap(layout.leftoverInventory[name])
        let written = Data("written meanwhile".utf8)
        try written.write(to: sandbox.legacy.appendingPathComponent(name))

        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .relocated
        )

        XCTAssertEqual(inventory(sandbox.target), layout.storeInventory)
        XCTAssertFalse(exists(sandbox.stagingRoot))
        let returned = inventory(sandbox.legacy)
        let renamed = try XCTUnwrap(
            returned.keys.first { layout.leftoverInventory[$0] == nil }
        )
        assertKeepBothName(renamed, of: name)
        var expected = layout.leftoverInventory
        expected[name] = written
        expected[renamed] = original
        XCTAssertEqual(returned, expected)
    }

    /// A crash mid-move, then a 4.2.x launch: it finds no store in the legacy
    /// folder and creates a fresh one there. The resumed move publishes the
    /// real store and keeps the fresh one aside instead of choosing between
    /// them destructively.
    func testInterruptedMoveFollowedByAnOlderV2LaunchConverges() async throws {
        let layout = try await makeHeadLayout()
        let sandbox = layout.sandbox
        XCTAssertThrowsError(
            try sandbox.relocation(
                faults: failing(.storeRelocationAfterLeftoverReturned)
            ).run(now: launchDate)
        )
        try await makeStore(
            at: sandbox.legacy,
            keyStore: layout.keyStore,
            texts: ["captured by 4.2.x"],
            includeBitmap: false
        )

        let outcome = try sandbox.relocation().run(now: launchDate)

        guard case .displacedLegacyStore(let displaced) = outcome else {
            return XCTFail("Expected a displacement, got \(outcome)")
        }
        XCTAssertTrue(
            displaced.lastPathComponent.hasSuffix(
                ClipboardHistoryStoreRelocation.pendingSuffix
            )
        )
        XCTAssertEqual(inventory(sandbox.target), layout.storeInventory)
        XCTAssertEqual(inventory(sandbox.legacy), layout.leftoverInventory)
        try await assertStoreOpens(
            at: sandbox.target,
            keyStore: layout.keyStore,
            entries: layout.entryCount
        )
        try await assertStoreOpens(
            at: displaced,
            keyStore: layout.keyStore,
            entries: 1
        )
    }

    /// Fixed release, then 4.2.x, then the fixed release again: both folders
    /// hold a store, and the one already in its own folder stays current.
    func testConflictKeepsTheCurrentStoreAndDisplacesTheLegacyOne()
        async throws
    {
        let interruptions: [ClipboardHistoryFaultPoint?] = [
            nil,
            .storeRelocationAfterDisplacement,
        ]
        for interruption in interruptions {
            let label = String(describing: interruption)
            let layout = try await makeHeadLayout()
            let sandbox = layout.sandbox
            XCTAssertEqual(
                try sandbox.relocation().run(now: launchDate),
                .relocated
            )
            let downgradeCount = try await makeStore(
                at: sandbox.legacy,
                keyStore: layout.keyStore,
                texts: ["during downgrade 1", "during downgrade 2"],
                includeBitmap: false
            )
            let targetBefore = inventory(sandbox.target)

            let displaced: URL
            if let interruption {
                XCTAssertThrowsError(
                    try sandbox.relocation(
                        faults: failing(interruption)
                    ).run(now: launchDate),
                    label
                )
                let names = childNames(sandbox.displacedRoot)
                XCTAssertEqual(names.count, 1, label)
                displaced = sandbox.displacedRoot.appendingPathComponent(
                    try XCTUnwrap(names.first)
                )
                XCTAssertEqual(
                    try sandbox.relocation().run(now: launchDate),
                    .nothingToRelocate,
                    label
                )
            } else {
                let outcome = try sandbox.relocation().run(now: launchDate)
                guard case .displacedLegacyStore(let url) = outcome else {
                    return XCTFail("Expected a displacement, got \(outcome)")
                }
                displaced = url
            }

            XCTAssertEqual(inventory(sandbox.target), targetBefore, label)
            XCTAssertEqual(
                inventory(sandbox.legacy),
                layout.leftoverInventory,
                label
            )
            XCTAssertEqual(
                displaced.deletingLastPathComponent().standardizedFileURL.path,
                sandbox.displacedRoot.standardizedFileURL.path,
                label
            )
            try await assertStoreOpens(
                at: sandbox.target,
                keyStore: layout.keyStore,
                entries: layout.entryCount
            )
            try await assertStoreOpens(
                at: displaced,
                keyStore: layout.keyStore,
                entries: downgradeCount
            )
        }
    }

    func testEmptyTargetSkeletonIsReplaced() async throws {
        let layout = try await makeHeadLayout()
        for name in ["payloads", "staging"] {
            try FileManager.default.createDirectory(
                at: layout.sandbox.target.appendingPathComponent(name),
                withIntermediateDirectories: true
            )
        }

        XCTAssertEqual(
            try layout.sandbox.relocation().run(now: launchDate),
            .relocated
        )

        assertFinalLayout(layout)
        XCTAssertFalse(exists(layout.sandbox.displacedRoot))
    }

    func testUnexpectedTargetContentIsMovedAsideNotDeleted() async throws {
        let layout = try await makeHeadLayout()
        try FileManager.default.createDirectory(
            at: layout.sandbox.target,
            withIntermediateDirectories: true
        )
        try Data("keep me".utf8).write(
            to: layout.sandbox.target.appendingPathComponent("notes.txt")
        )

        XCTAssertEqual(
            try layout.sandbox.relocation().run(now: launchDate),
            .relocated
        )

        assertFinalLayout(layout)
        let aside = childNames(layout.sandbox.displacedRoot)
        XCTAssertEqual(aside.count, 1)
        XCTAssertFalse(
            aside.first?.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                ?? true
        )
        XCTAssertEqual(
            inventory(
                layout.sandbox.displacedRoot.appendingPathComponent(
                    try XCTUnwrap(aside.first)
                )
            ),
            ["notes.txt": Data("keep me".utf8)]
        )
    }

    func testPreV2SweepsAfterTheMoveCannotReachTheStore() async throws {
        let layout = try await makeHeadLayout()
        XCTAssertEqual(
            try layout.sandbox.relocation().run(now: launchDate),
            .relocated
        )

        PreV2ClipboardHistorySweep.removeOrphanPNGFiles(
            in: layout.sandbox.legacy,
            keeping: []
        )
        PreV2ClipboardHistorySweep.removeOrphanFiles(
            in: layout.sandbox.legacy,
            keeping: []
        )
        PreV2ClipboardHistorySweep.clearAll(in: layout.sandbox.legacy)

        XCTAssertEqual(inventory(layout.sandbox.target), layout.storeInventory)
        try await assertStoreOpens(
            at: layout.sandbox.target,
            keyStore: layout.keyStore,
            entries: layout.entryCount
        )
    }

    func testFailedMoveChangesNothingAndARetryFinishesIt() async throws {
        let layout = try await makeHeadLayout()
        let sandbox = layout.sandbox
        let before = inventory(sandbox.legacy)
        XCTAssertEqual(chmod(sandbox.root.path, 0o500), 0)

        XCTAssertThrowsError(try sandbox.relocation().run(now: launchDate)) {
            XCTAssertEqual(
                $0 as? ClipboardHistoryStorageError,
                .fileOperationFailed(EACCES)
            )
        }

        XCTAssertEqual(chmod(sandbox.root.path, 0o700), 0)
        XCTAssertEqual(inventory(sandbox.legacy), before)
        XCTAssertFalse(exists(sandbox.target))
        XCTAssertFalse(exists(sandbox.stagingRoot))
        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .relocated
        )
        assertFinalLayout(layout)
    }

    func testDisplacementNamesSortChronologically() throws {
        let first = ClipboardHistoryStoreRelocation.displacementName(
            at: launchDate
        )
        let second = ClipboardHistoryStoreRelocation.displacementName(
            at: launchDate.addingTimeInterval(1)
        )

        let stamp = "20261001T050607Z-"
        XCTAssertTrue(first.hasPrefix(stamp), first)
        let suffix = first.dropFirst(stamp.count)
        XCTAssertEqual(suffix.count, 8, first)
        XCTAssertTrue(
            suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            first
        )
        XCTAssertLessThan(first, second)
    }

    func testStoreHeldOpenByAnotherProcessIsNotMoved() throws {
        let sandbox = try makeSandbox()
        let database = try makePlainWALDatabase(in: sandbox.legacy)
        try Data("pre-v2".utf8).write(
            to: sandbox.legacy.appendingPathComponent("A.png")
        )
        let connection = try ForeignConnection(database: database)
        defer { connection.close() }
        XCTAssertEqual(
            ClipboardHistoryStoreRelocation.processHoldingStoreOpen(
                in: sandbox.legacy
            ),
            connection.pid
        )
        let before = childNames(sandbox.legacy)

        XCTAssertThrowsError(try sandbox.relocation().run(now: launchDate)) {
            XCTAssertEqual(
                $0 as? ClipboardHistoryStorageError,
                .fileOperationFailed(EBUSY)
            )
        }

        XCTAssertEqual(childNames(sandbox.legacy), before)
        XCTAssertFalse(exists(sandbox.target))
        XCTAssertFalse(exists(sandbox.stagingRoot))

        connection.close()
        XCTAssertNil(
            ClipboardHistoryStoreRelocation.processHoldingStoreOpen(
                in: sandbox.legacy
            )
        )
        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .relocated
        )
        XCTAssertTrue(
            exists(sandbox.target.appendingPathComponent("history.sqlite"))
        )
        XCTAssertEqual(childNames(sandbox.legacy), ["A.png"])
    }

    func testStoreHeldOpenElsewhereIsPostponedWhenTheNewRootHoldsAStore()
        async throws
    {
        let sandbox = try makeSandbox()
        try await makeStore(
            at: sandbox.target,
            keyStore: CountingKeyStore(key: masterKey),
            texts: ["moved"],
            includeBitmap: false
        )
        let database = try makePlainWALDatabase(in: sandbox.legacy)
        let connection = try ForeignConnection(database: database)
        defer { connection.close() }
        let before = childNames(sandbox.legacy)

        XCTAssertEqual(
            try sandbox.relocation().run(now: launchDate),
            .postponedWhileLegacyStoreInUse(connection.pid)
        )

        XCTAssertEqual(childNames(sandbox.legacy), before)
        XCTAssertFalse(exists(sandbox.stagingRoot))
        XCTAssertFalse(exists(sandbox.displacedRoot))
    }

    // MARK: - Module wiring

    func testInitMovesTheLegacyStoreBeforeOpeningIt() async throws {
        let layout = try await makeHeadLayout()
        let loadsBefore = layout.keyStore.loadCount

        let module = layout.sandbox.module(in: self, keyStore: layout.keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, layout.entryCount)
        try await assertEveryEntryMaterializes(module)
        XCTAssertEqual(
            inventory(layout.sandbox.legacy),
            layout.leftoverInventory
        )
        XCTAssertEqual(layout.keyStore.loadCount - loadsBefore, 1)
        XCTAssertEqual(layout.keyStore.createCount, 0)
        XCTAssertEqual(layout.keyStore.deleteCount, 0)
        try await module.closeStoreForTesting()
    }

    /// A move that cannot run blocks before the Keychain is touched: no key
    /// is created, nothing appears at the new root, and Reset (which would
    /// destroy the intact store) is refused. A retry finishes the move.
    func testRelocationFailureIsUnavailableBeforeAnyKeychainAccess()
        async throws
    {
        let layout = try await makeHeadLayout()
        let sandbox = layout.sandbox
        let before = inventory(sandbox.legacy)
        let loadsBefore = layout.keyStore.loadCount
        XCTAssertEqual(chmod(sandbox.root.path, 0o500), 0)

        let module = sandbox.module(in: self, keyStore: layout.keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .unavailable)
        XCTAssertEqual(status.reason, .storeRelocationFailed)
        XCTAssertEqual(layout.keyStore.loadCount, loadsBefore)
        XCTAssertEqual(layout.keyStore.createCount, 0)
        do {
            try await module.reset(confirmation: .confirmed)
            XCTFail("Reset must be refused while the move is unfinished")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .resetFailed
            )
        }
        XCTAssertEqual(layout.keyStore.deleteCount, 0)
        XCTAssertEqual(chmod(sandbox.root.path, 0o700), 0)
        XCTAssertEqual(inventory(sandbox.legacy), before)
        XCTAssertFalse(exists(sandbox.target))

        await module.retry()

        let retried = await module.status()
        XCTAssertEqual(retried.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, layout.entryCount)
        XCTAssertEqual(layout.keyStore.createCount, 0)
        try await module.closeStoreForTesting()
    }

    func testInterruptedMoveIsUnavailableAndTheNextLaunchFinishesIt()
        async throws
    {
        let interruptions: [ClipboardHistoryFaultPoint] = [
            .storeRelocationAfterDetach,
            .storeRelocationAfterLeftoverReturned,
            .storeRelocationBeforePublication,
        ]
        for point in interruptions {
            let label = "\(point)"
            let layout = try await makeHeadLayout()
            let sandbox = layout.sandbox
            let loadsBefore = layout.keyStore.loadCount

            let interrupted = sandbox.module(in: self, keyStore: layout.keyStore,
                faults: ClipboardHistoryFaultInjector(points: [point])
            )

            let status = await interrupted.status()
            XCTAssertEqual(status.availability, .unavailable, label)
            XCTAssertEqual(status.reason, .storeRelocationFailed, label)
            XCTAssertEqual(layout.keyStore.loadCount, loadsBefore, label)
            XCTAssertFalse(exists(sandbox.target), label)
            assertNothingLost(layout, label)

            let relaunched = sandbox.module(in: self, keyStore: layout.keyStore)
            let relaunchedStatus = await relaunched.status()
            XCTAssertEqual(relaunchedStatus.availability, .ready, label)
            let count = try await entryCount(of: relaunched)
            XCTAssertEqual(count, layout.entryCount, label)
            try await assertEveryEntryMaterializes(relaunched)
            XCTAssertEqual(
                inventory(sandbox.legacy),
                layout.leftoverInventory,
                label
            )
            XCTAssertFalse(exists(sandbox.stagingRoot), label)
            XCTAssertEqual(layout.keyStore.createCount, 0, label)
            XCTAssertEqual(layout.keyStore.deleteCount, 0, label)
            try await relaunched.closeStoreForTesting()
        }
    }

    func testFailureAfterPublicationStillOpensTheMovedStore() async throws {
        let layout = try await makeHeadLayout()

        let module = layout.sandbox.module(in: self, keyStore: layout.keyStore,
            faults: ClipboardHistoryFaultInjector(
                points: [.storeRelocationAfterPublication]
            )
        )

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, layout.entryCount)
        XCTAssertEqual(
            inventory(layout.sandbox.legacy),
            layout.leftoverInventory
        )
        try await module.closeStoreForTesting()
    }

    /// An older release still running on the legacy folder must not take
    /// down a store that already lives in its own folder: moving the legacy
    /// store waits, and Reset, which would orphan it, is refused until then.
    func testLegacyStoreInUseDoesNotBlockAStoreAlreadyMoved() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["already moved"],
            includeBitmap: false
        )
        let database = try makePlainWALDatabase(in: sandbox.legacy)
        let connection = try ForeignConnection(database: database)
        defer { connection.close() }
        let legacyBefore = childNames(sandbox.legacy)

        let module = sandbox.module(in: self, keyStore: keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        XCTAssertNil(status.reason)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(childNames(sandbox.legacy), legacyBefore)
        do {
            try await module.reset(confirmation: .confirmed)
            XCTFail("Reset must wait until the legacy store has moved")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .resetFailed
            )
        }
        XCTAssertEqual(keyStore.deleteCount, 0)
        let afterRefusal = await module.status()
        XCTAssertEqual(afterRefusal.availability, .ready)

        connection.close()
        await module.retry()

        let retried = await module.status()
        XCTAssertEqual(retried.availability, .ready)
        let retriedCount = try await entryCount(of: module)
        XCTAssertEqual(retriedCount, 1)
        XCTAssertFalse(exists(sandbox.legacy))
        let kept = childNames(sandbox.displacedRoot)
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(
            kept.first?.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                ?? true
        )
        try await module.closeStoreForTesting()
    }

    // MARK: - Displaced stores

    func testEmptyCurrentStoreAdoptsTheDisplacedStore() async throws {
        let layout = try await makeAdoptionLayout()
        let loadsBefore = layout.keyStore.loadCount

        let module = layout.sandbox.module(in: self, keyStore: layout.keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        XCTAssertEqual(
            layout.keyStore.loadCount - loadsBefore,
            1,
            "Weighing and adopting reuse the key the launch already loaded"
        )
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, layout.legacyCount)
        try await assertEveryEntryMaterializes(module)
        try await module.closeStoreForTesting()
        XCTAssertEqual(
            childNames(layout.sandbox.displacedRoot),
            [],
            "The swapped-out empty store is removed"
        )
        XCTAssertFalse(exists(layout.sandbox.legacy))
        XCTAssertEqual(layout.keyStore.createCount, 0)
        XCTAssertEqual(layout.keyStore.deleteCount, 0)
    }

    func testAdoptionResumesAfterEveryInterruption() async throws {
        let interruptions: [ClipboardHistoryFaultPoint] = [
            .storeRelocationAfterDisplacement,
            .storeRelocationBeforeAdoption,
            .storeRelocationAfterAdoption,
        ]
        for point in interruptions {
            let label = "\(point)"
            let layout = try await makeAdoptionLayout()

            let interrupted = layout.sandbox.module(in: self, keyStore: layout.keyStore,
                faults: ClipboardHistoryFaultInjector(points: [point])
            )

            // Whatever the interruption, the launch still opens a readable
            // store and keeps the other one pending.
            let status = await interrupted.status()
            XCTAssertEqual(status.availability, .ready, label)
            let count = try await entryCount(of: interrupted)
            XCTAssertEqual(count, 0, label)
            try await interrupted.closeStoreForTesting()
            XCTAssertEqual(
                childNames(layout.sandbox.displacedRoot).filter {
                    $0.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                }.count,
                1,
                label
            )

            try await assertAdopted(layout, label)
        }
    }

    /// A crash right after the atomic swap leaves the adopted store in place
    /// and the empty one under the candidate's pending name.
    func testCrashRightAfterTheSwapConverges() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        let adoptedCount = try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["a", "b"]
        )
        try FileManager.default.createDirectory(
            at: sandbox.displacedRoot,
            withIntermediateDirectories: true
        )
        try await makeStore(
            at: sandbox.displacedRoot.appendingPathComponent(
                "20261001T050607Z-0badcafe.pending"
            ),
            keyStore: keyStore,
            texts: [],
            includeBitmap: false
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, adoptedCount)
        try await module.closeStoreForTesting()
        XCTAssertEqual(childNames(sandbox.displacedRoot), [])
    }

    func testLockedKeychainPostponesAdoption() async throws {
        let layout = try await makeAdoptionLayout()

        let locked = layout.sandbox.module(in: self, keyStore: LockedKeyStore())

        let status = await locked.status()
        XCTAssertEqual(status.availability, .paused)
        XCTAssertEqual(status.reason, .keychainLocked)
        let pending = childNames(layout.sandbox.displacedRoot)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(
            pending.first?.hasSuffix(
                ClipboardHistoryStoreRelocation.pendingSuffix
            ) ?? false
        )
        try await assertAdopted(layout)
    }

    func testPopulatedCurrentStoreKeepsTheDisplacedStoreAside() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["kept"],
            includeBitmap: false
        )
        let legacyCount = try await makeStore(
            at: sandbox.legacy,
            keyStore: keyStore,
            texts: ["x", "y"]
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 1)
        try await module.closeStoreForTesting()
        let aside = childNames(sandbox.displacedRoot)
        XCTAssertEqual(aside.count, 1)
        XCTAssertFalse(
            aside.first?.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                ?? true
        )
        try await assertStoreOpens(
            at: sandbox.displacedRoot.appendingPathComponent(
                try XCTUnwrap(aside.first)
            ),
            keyStore: keyStore,
            entries: legacyCount
        )
    }

    /// A displaced store that does not open with the current key is never
    /// swapped in, even over an empty store, and the working store keeps
    /// working.
    func testCandidateUnderAnotherKeyIsNeverAdopted() async throws {
        let sandbox = try makeSandbox()
        let otherKeyStore = CountingKeyStore(
            key: Data(repeating: 0x41, count: 32)
        )
        let legacyCount = try await makeStore(
            at: sandbox.legacy,
            keyStore: otherKeyStore,
            texts: ["under another key"]
        )
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: [],
            includeBitmap: false
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 0)
        _ = try await module.capture(
            ClipboardHistoryCaptureRequest(
                source: captureSource,
                content: .text("still working")
            )
        )
        let afterCapture = try await entryCount(of: module)
        XCTAssertEqual(afterCapture, 1)
        try await module.closeStoreForTesting()
        let aside = childNames(sandbox.displacedRoot)
        XCTAssertEqual(aside.count, 1)
        XCTAssertFalse(
            aside.first?.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                ?? true
        )

        let relaunched = sandbox.module(in: self, keyStore: keyStore)
        let relaunchedStatus = await relaunched.status()
        XCTAssertEqual(relaunchedStatus.availability, .ready)
        let relaunchedCount = try await entryCount(of: relaunched)
        XCTAssertEqual(relaunchedCount, 1)
        try await relaunched.closeStoreForTesting()
        XCTAssertEqual(childNames(sandbox.displacedRoot), aside)
        XCTAssertEqual(keyStore.createCount, 0)
        XCTAssertEqual(keyStore.deleteCount, 0)
        try await assertStoreOpens(
            at: sandbox.displacedRoot.appendingPathComponent(
                try XCTUnwrap(aside.first)
            ),
            keyStore: otherKeyStore,
            entries: legacyCount
        )
    }

    func testEmptyDisplacedStoreIsRemoved() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["kept"],
            includeBitmap: false
        )
        try await makeStore(
            at: sandbox.legacy,
            keyStore: keyStore,
            texts: [],
            includeBitmap: false
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 1)
        try await module.closeStoreForTesting()
        XCTAssertEqual(childNames(sandbox.displacedRoot), [])
        XCTAssertFalse(exists(sandbox.legacy))
    }

    /// Settling never replaces a folder that already has the settled name.
    func testSettlingKeepsAFolderWithTheSameName() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["current"],
            includeBitmap: false
        )
        let settledName = "20261001T050607Z-0badcafe"
        let existing = sandbox.displacedRoot.appendingPathComponent(
            settledName
        )
        try FileManager.default.createDirectory(
            at: existing,
            withIntermediateDirectories: true
        )
        try Data("already here".utf8).write(
            to: existing.appendingPathComponent("notes.txt")
        )
        let candidateCount = try await makeStore(
            at: sandbox.displacedRoot.appendingPathComponent(
                settledName + ClipboardHistoryStoreRelocation.pendingSuffix
            ),
            keyStore: keyStore,
            texts: ["kept aside"],
            includeBitmap: false
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 1)
        try await module.closeStoreForTesting()
        let names = childNames(sandbox.displacedRoot)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(
            inventory(existing),
            ["notes.txt": Data("already here".utf8)]
        )
        let renamed = try XCTUnwrap(
            names.first { $0 != settledName }
        )
        assertKeepBothName(renamed, of: settledName)
        try await assertStoreOpens(
            at: sandbox.displacedRoot.appendingPathComponent(renamed),
            keyStore: keyStore,
            entries: candidateCount
        )
    }

    /// Another running copy of AnyDoor (the installed app beside a `swift
    /// run` build, say) has the empty current store open. Swapping the
    /// displaced store in would move the files out from under it: what it
    /// captures next would vanish with the swapped-out store, and its
    /// payload maintenance, which follows the store folder by name, would
    /// reclaim the adopted store's payloads. Adoption waits until it quits.
    func testAdoptionWaitsWhileAnotherProcessHasTheCurrentStoreOpen()
        async throws
    {
        let layout = try await makeAdoptionLayout()
        let sandbox = layout.sandbox
        let holder = try StoreHolderProcess(
            holding: sandbox.target,
            testBundle: Bundle(for: Self.self).bundleURL
        )
        defer { holder.terminate() }
        XCTAssertEqual(
            ClipboardHistoryStoreRelocation.processHoldingStoreOpen(
                in: sandbox.target
            ),
            holder.pid
        )
        let heldDatabase = inode(
            of: sandbox.target.appendingPathComponent("history.sqlite")
        )

        let module = sandbox.module(in: self, keyStore: layout.keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 0)
        try await module.closeStoreForTesting()
        XCTAssertEqual(
            inode(of: sandbox.target.appendingPathComponent("history.sqlite")),
            heldDatabase
        )
        let pending = childNames(sandbox.displacedRoot)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(
            pending.first?.hasSuffix(
                ClipboardHistoryStoreRelocation.pendingSuffix
            ) ?? false
        )

        try holder.captureAndQuit("captured by the other copy")

        // Nothing the other copy saved is lost, and now that the current
        // store holds history the displaced one is kept aside.
        let relaunched = sandbox.module(in: self, keyStore: layout.keyStore)
        let texts = try await entryTexts(of: relaunched)
        XCTAssertEqual(texts, ["captured by the other copy"])
        try await relaunched.closeStoreForTesting()
        let kept = childNames(sandbox.displacedRoot)
        XCTAssertEqual(kept.count, 1)
        XCTAssertFalse(
            kept.first?.hasSuffix(ClipboardHistoryStoreRelocation.pendingSuffix)
                ?? true
        )
        try await assertStoreOpens(
            at: sandbox.displacedRoot.appendingPathComponent(
                try XCTUnwrap(kept.first)
            ),
            keyStore: layout.keyStore,
            entries: layout.legacyCount
        )
    }

    /// The same holds for a displaced store another process has open, such
    /// as an older release that opened its store just as it was moved.
    func testAdoptionWaitsWhileAnotherProcessHasTheDisplacedStoreOpen()
        async throws
    {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: [],
            includeBitmap: false
        )
        let candidate = sandbox.displacedRoot.appendingPathComponent(
            "20261001T050607Z-0badcafe"
                + ClipboardHistoryStoreRelocation.pendingSuffix
        )
        try FileManager.default.createDirectory(
            at: sandbox.displacedRoot,
            withIntermediateDirectories: true
        )
        let candidateCount = try await makeStore(
            at: candidate,
            keyStore: keyStore,
            texts: ["kept aside"]
        )
        let holder = try StoreHolderProcess(
            holding: candidate,
            testBundle: Bundle(for: Self.self).bundleURL
        )
        defer { holder.terminate() }
        XCTAssertEqual(
            ClipboardHistoryStoreRelocation.processHoldingStoreOpen(
                in: candidate
            ),
            holder.pid
        )

        let module = sandbox.module(in: self, keyStore: keyStore)

        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 0)
        try await module.closeStoreForTesting()
        XCTAssertEqual(
            childNames(sandbox.displacedRoot),
            [candidate.lastPathComponent]
        )

        try holder.captureAndQuit("captured while kept aside")

        let relaunched = sandbox.module(in: self, keyStore: keyStore)
        let relaunchedCount = try await entryCount(of: relaunched)
        XCTAssertEqual(relaunchedCount, candidateCount + 1)
        let texts = try await entryTexts(of: relaunched)
        XCTAssertTrue(texts.contains("captured while kept aside"), "\(texts)")
        try await assertEveryEntryMaterializes(relaunched)
        try await relaunched.closeStoreForTesting()
        XCTAssertEqual(childNames(sandbox.displacedRoot), [])
        XCTAssertEqual(keyStore.createCount, 0)
        XCTAssertEqual(keyStore.deleteCount, 0)
    }

    /// Not a test on its own: `StoreHolderProcess` runs it in a child
    /// process, which holds a store open the way another running copy of
    /// AnyDoor does until it is told to capture and quit.
    func testHoldStoreOpenAsAnotherProcess() async throws {
        guard
            let path = ProcessInfo.processInfo.environment[
                StoreHolderProcess.storeRootEnvironment
            ]
        else {
            throw XCTSkip("Runs only as the child of StoreHolderProcess")
        }
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: URL(fileURLWithPath: path),
            keyStore: CountingKeyStore(key: masterKey)
        ))
        let status = await module.status()
        guard status.availability == .ready else {
            return XCTFail("Store did not open: \(String(describing: status))")
        }
        FileHandle.standardOutput.write(
            Data("\(StoreHolderProcess.readyLine)\n".utf8)
        )
        if let text = readLine(), !text.isEmpty {
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: captureSource,
                    content: .text(text)
                )
            )
        }
        try await module.closeStoreForTesting()
        FileHandle.standardOutput.write(
            Data("\(StoreHolderProcess.closedLine)\n".utf8)
        )
    }

    // MARK: - Storage usage and reset

    func testStorageUsageCountsDisplacedStores() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeDisplacedStoreLayout(in: sandbox, keyStore: keyStore)
        let module = sandbox.module(in: self, keyStore: keyStore)
        await module.awaitSearchIndexRebuildForTesting()
        await module.awaitDerivedJobsForTesting()
        let displacedBytes = allocatedBytes(sandbox.displacedRoot)
        XCTAssertGreaterThan(displacedBytes, 0)

        let withDisplaced = try await module.storageUsage()
        let setAside = sandbox.root.deletingLastPathComponent()
            .appendingPathComponent("set-aside")
        try FileManager.default.moveItem(
            at: sandbox.displacedRoot,
            to: setAside
        )
        let withoutDisplaced = try await module.storageUsage()
        try FileManager.default.moveItem(
            at: setAside,
            to: sandbox.displacedRoot
        )

        XCTAssertEqual(withDisplaced, withoutDisplaced + displacedBytes)
        XCTAssertEqual(withoutDisplaced, allocatedBytes(sandbox.target))
        try await module.closeStoreForTesting()
    }

    func testUnmeasurableDisplacedStoresNeverFailMaintenance() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeDisplacedStoreLayout(in: sandbox, keyStore: keyStore)
        let displacedPath = sandbox.displacedRoot.standardizedFileURL.path
        let refusals = OSAllocatedUnfairLock(initialState: 0)
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: sandbox.target,
            legacyStoreRoot: sandbox.legacy,
            keyStore: keyStore,
            storageTraversalHook: { url in
                guard
                    url.standardizedFileURL.path.hasPrefix(displacedPath + "/")
                else {
                    return
                }
                refusals.withLock { $0 += 1 }
                throw ClipboardHistoryStorageError.fileOperationFailed(EACCES)
            }
        ))
        await module.awaitSearchIndexRebuildForTesting()
        await module.awaitDerivedJobsForTesting()
        XCTAssertGreaterThan(allocatedBytes(sandbox.displacedRoot), 0)

        let usage = try await module.storageUsage()

        XCTAssertEqual(usage, allocatedBytes(sandbox.target))
        XCTAssertGreaterThan(refusals.withLock { $0 }, 0)
        do {
            let report = try await module.performMaintenance()
            XCTAssertGreaterThan(report.storageBytes, 0)
        } catch {
            XCTFail("Maintenance failed: \(error)")
        }
        try await module.closeStoreForTesting()
    }

    func testResetRemovesDisplacedStores() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeDisplacedStoreLayout(in: sandbox, keyStore: keyStore)
        let module = sandbox.module(in: self, keyStore: keyStore)
        XCTAssertEqual(childNames(sandbox.displacedRoot).count, 1)

        try await module.reset(confirmation: .confirmed)

        XCTAssertFalse(exists(sandbox.displacedRoot))
        XCTAssertEqual(keyStore.deleteCount, 1)
        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, 0)
        try await module.closeStoreForTesting()
    }

    func testResetIsRefusedWhileAMoveIsHalfDone() async throws {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["current"],
            includeBitmap: false
        )
        try await makeStore(
            at: sandbox.legacy,
            keyStore: keyStore,
            texts: ["older release"],
            includeBitmap: false
        )
        let module = sandbox.module(in: self, keyStore: keyStore,
            faults: ClipboardHistoryFaultInjector(
                points: [.storeRelocationAfterDetach]
            )
        )
        let status = await module.status()
        XCTAssertEqual(status.availability, .ready)
        XCTAssertTrue(exists(sandbox.stagingRoot))

        do {
            try await module.reset(confirmation: .confirmed)
            XCTFail("Reset must wait until the move has finished")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .resetFailed
            )
        }

        XCTAssertEqual(keyStore.deleteCount, 0)
        XCTAssertTrue(exists(sandbox.stagingRoot))
        let afterRefusal = await module.status()
        XCTAssertEqual(afterRefusal.availability, .ready)

        // The detach already happened, so the injected fault does not recur.
        await module.retry()
        XCTAssertFalse(exists(sandbox.stagingRoot))
        XCTAssertEqual(childNames(sandbox.displacedRoot).count, 1)

        try await module.reset(confirmation: .confirmed)
        XCTAssertEqual(keyStore.deleteCount, 1)
        XCTAssertFalse(exists(sandbox.displacedRoot))
        try await module.closeStoreForTesting()
    }

    // MARK: - Fixtures

    /// `Application Support/dev.bybee.AnyDoor` in a temporary folder.
    private struct Sandbox {
        let root: URL

        var legacy: URL { root.appendingPathComponent("ClipboardHistory") }
        var target: URL { root.appendingPathComponent("ClipboardHistoryV2") }
        var stagingRoot: URL {
            root.appendingPathComponent("ClipboardHistoryV2.relocating")
        }
        var displacedRoot: URL {
            root.appendingPathComponent("ClipboardHistoryV2.displaced")
        }

        func relocation(
            faults: ClipboardHistoryFaultInjector =
                ClipboardHistoryFaultInjector()
        ) -> ClipboardHistoryStoreRelocation {
            ClipboardHistoryStoreRelocation(
                legacyRoot: legacy,
                storeRoot: target,
                faultInjector: faults
            )
        }

        func module(
            in testCase: XCTestCase,
            keyStore: any ClipboardHistoryMasterKeyStoring,
            faults: ClipboardHistoryFaultInjector =
                ClipboardHistoryFaultInjector()
        ) -> ClipboardHistoryModule {
            testCase.trackClipboardHistoryModule(ClipboardHistoryModule(
                testingStoreRoot: target,
                legacyStoreRoot: legacy,
                keyStore: keyStore,
                faultInjector: faults
            ))
        }
    }

    private struct HeadLayout {
        let sandbox: Sandbox
        let keyStore: CountingKeyStore
        let storeInventory: [String: Data]
        let leftoverInventory: [String: Data]
        let entryCount: Int
    }

    private struct AdoptionLayout {
        let sandbox: Sandbox
        let keyStore: CountingKeyStore
        let legacyCount: Int
    }

    private func makeSandbox() throws -> Sandbox {
        let top = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-StoreRelocation-\(UUID().uuidString)",
                isDirectory: true
            )
        let root = top.appendingPathComponent(
            "dev.bybee.AnyDoor",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            restoreOwnerPermissions(top)
            try? FileManager.default.removeItem(at: top)
        }
        return Sandbox(root: root)
    }

    /// A 4.2.x layout as a quit or killed app leaves it (the WAL still holds
    /// committed transactions), plus pre-v2 payloads awaiting migration.
    private func makeHeadLayout(leftovers: Int = 3) async throws -> HeadLayout {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        let live = sandbox.root.deletingLastPathComponent()
            .appendingPathComponent("live")
        let module = try await makeOpenStore(
            at: live,
            keyStore: keyStore,
            texts: ["alpha", "beta", "gamma"],
            includeBitmap: true
        )
        let count = try await entryCount(of: module)
        try FileManager.default.copyItem(at: live, to: sandbox.legacy)
        try await module.closeStoreForTesting()
        try FileManager.default.removeItem(at: live)
        let storeInventory = inventory(sandbox.legacy)
        XCTAssertGreaterThan(
            storeInventory["history.sqlite-wal"]?.count ?? 0,
            0
        )
        for index in 0..<leftovers {
            try Data("pre-v2 payload \(index)".utf8).write(
                to: sandbox.legacy.appendingPathComponent(
                    "\(UUID().uuidString).png"
                )
            )
        }
        let leftoverInventory = inventory(sandbox.legacy).filter {
            storeInventory[$0.key] == nil
        }
        XCTAssertEqual(leftoverInventory.count, leftovers)
        return HeadLayout(
            sandbox: sandbox,
            keyStore: keyStore,
            storeInventory: storeInventory,
            leftoverInventory: leftoverInventory,
            entryCount: count
        )
    }

    /// The new root holds an empty store (as after a failed migration), and
    /// the legacy folder a populated one an older v2 release wrote under
    /// the same key.
    private func makeAdoptionLayout() async throws -> AdoptionLayout {
        let sandbox = try makeSandbox()
        let keyStore = CountingKeyStore(key: masterKey)
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: [],
            includeBitmap: false
        )
        let legacyCount = try await makeStore(
            at: sandbox.legacy,
            keyStore: keyStore,
            texts: ["a", "b"]
        )
        return AdoptionLayout(
            sandbox: sandbox,
            keyStore: keyStore,
            legacyCount: legacyCount
        )
    }

    /// Both folders hold populated stores, so the next launch keeps the
    /// legacy one aside.
    private func makeDisplacedStoreLayout(
        in sandbox: Sandbox,
        keyStore: CountingKeyStore
    ) async throws {
        try await makeStore(
            at: sandbox.target,
            keyStore: keyStore,
            texts: ["current"]
        )
        try await makeStore(
            at: sandbox.legacy,
            keyStore: keyStore,
            texts: ["kept aside"]
        )
    }

    private func makeOpenStore(
        at root: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        texts: [String],
        includeBitmap: Bool
    ) async throws -> ClipboardHistoryModule {
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: keyStore
        ))
        let status = await module.status()
        XCTAssertEqual(
            status.availability,
            .ready,
            String(describing: status.reason)
        )
        for text in texts {
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: captureSource,
                    content: .text(text)
                )
            )
        }
        if includeBitmap {
            _ = try await module.capture(
                ClipboardHistoryCaptureRequest(
                    source: captureSource,
                    content: .bitmap(
                        try tinyPNG(),
                        provenance: .anyDoorScreenshot
                    )
                )
            )
        }
        await module.awaitSearchIndexRebuildForTesting()
        await module.awaitDerivedJobsForTesting()
        return module
    }

    /// Builds and closes a ready store at `root` holding `texts` and,
    /// optionally, one bitmap (so `payloads/` holds a real encrypted
    /// payload). Returns its entry count.
    @discardableResult
    private func makeStore(
        at root: URL,
        keyStore: any ClipboardHistoryMasterKeyStoring,
        texts: [String],
        includeBitmap: Bool = true
    ) async throws -> Int {
        let module = try await makeOpenStore(
            at: root,
            keyStore: keyStore,
            texts: texts,
            includeBitmap: includeBitmap
        )
        let count = try await entryCount(of: module)
        try await module.closeStoreForTesting()
        return count
    }

    /// A plain SQLite database in WAL mode named like the store, written by
    /// the system `sqlite3` so another process can hold it open.
    private func makePlainWALDatabase(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let database = directory.appendingPathComponent("history.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            database.path,
            "PRAGMA journal_mode=WAL; CREATE TABLE t(x); INSERT INTO t VALUES(1);",
        ]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return database
    }

    private func failing(
        _ point: ClipboardHistoryFaultPoint,
        occurrence: Int = 1
    ) -> ClipboardHistoryFaultInjector {
        let seen = OSAllocatedUnfairLock(initialState: 0)
        return ClipboardHistoryFaultInjector { candidate in
            guard candidate == point else { return false }
            return seen.withLock { count in
                count += 1
                return count == occurrence
            }
        }
    }

    // MARK: - Assertions

    private func assertStoreOpens(
        at root: URL,
        keyStore: CountingKeyStore,
        entries expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let module = trackClipboardHistoryModule(ClipboardHistoryModule(
            testingStoreRoot: root,
            keyStore: keyStore
        ))
        let status = await module.status()
        XCTAssertEqual(
            status.availability,
            .ready,
            String(describing: status.reason),
            file: file,
            line: line
        )
        let count = try await entryCount(of: module)
        XCTAssertEqual(count, expected, file: file, line: line)
        try await assertEveryEntryMaterializes(module, file: file, line: line)
        XCTAssertEqual(keyStore.createCount, 0, file: file, line: line)
        XCTAssertEqual(keyStore.deleteCount, 0, file: file, line: line)
        try await module.closeStoreForTesting()
    }

    /// Every entry, bitmaps included, still decrypts: `payloads/` moved
    /// together with the database.
    private func assertEveryEntryMaterializes(
        _ module: ClipboardHistoryModule,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var cursor: ClipboardHistoryCursor?
        repeat {
            let page = try await module.page(
                ClipboardHistoryQuery(),
                after: cursor
            )
            for entry in page.entries {
                let materialized = try await module.materialize(
                    ClipboardHistoryMaterializationRequest(
                        entryID: entry.id,
                        purpose: .fullPreview
                    )
                )
                XCTAssertFalse(
                    materialized.items.isEmpty,
                    file: file,
                    line: line
                )
            }
            cursor = page.nextCursor
        } while cursor != nil
    }

    private func assertAdopted(
        _ layout: AdoptionLayout,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let module = layout.sandbox.module(in: self, keyStore: layout.keyStore)
        let status = await module.status()
        XCTAssertEqual(
            status.availability,
            .ready,
            message,
            file: file,
            line: line
        )
        let count = try await entryCount(of: module)
        XCTAssertEqual(
            count,
            layout.legacyCount,
            message,
            file: file,
            line: line
        )
        try await assertEveryEntryMaterializes(module, file: file, line: line)
        try await module.closeStoreForTesting()
        XCTAssertEqual(
            childNames(layout.sandbox.displacedRoot),
            [],
            message,
            file: file,
            line: line
        )
        XCTAssertFalse(
            exists(layout.sandbox.legacy),
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            layout.keyStore.createCount,
            0,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            layout.keyStore.deleteCount,
            0,
            message,
            file: file,
            line: line
        )
    }

    /// `<name>.relocated-<8 hex digits>`: the name an item moves to when its
    /// own name is already taken.
    private func assertKeepBothName(
        _ renamed: String,
        of name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prefix = "\(name).relocated-"
        XCTAssertTrue(renamed.hasPrefix(prefix), renamed, file: file, line: line)
        let suffix = renamed.dropFirst(prefix.count)
        XCTAssertEqual(suffix.count, 8, renamed, file: file, line: line)
        XCTAssertTrue(
            suffix.allSatisfy { $0.isHexDigit && !$0.isUppercase },
            renamed,
            file: file,
            line: line
        )
    }

    /// Every file of the original layout still exists, byte-identical,
    /// somewhere in the sandbox: nothing was deleted or rewritten.
    private func assertNothingLost(
        _ layout: HeadLayout,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var contents: [Data: Int] = [:]
        for (path, data) in inventory(layout.sandbox.root)
        where !path.hasSuffix("/") {
            contents[data, default: 0] += 1
        }
        let original = layout.storeInventory.merging(
            layout.leftoverInventory,
            uniquingKeysWith: { first, _ in first }
        )
        for (path, data) in original where !path.hasSuffix("/") {
            XCTAssertNotNil(
                contents[data],
                "Lost \(path) \(message)",
                file: file,
                line: line
            )
        }
    }

    private func assertFinalLayout(
        _ layout: HeadLayout,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            inventory(layout.sandbox.target),
            layout.storeInventory,
            message,
            file: file,
            line: line
        )
        XCTAssertEqual(
            inventory(layout.sandbox.legacy),
            layout.leftoverInventory,
            message,
            file: file,
            line: line
        )
        XCTAssertFalse(
            exists(layout.sandbox.stagingRoot),
            message,
            file: file,
            line: line
        )
    }
}

// MARK: - Test doubles and helpers

/// In-memory stand-in for the Keychain item that counts every call, so a
/// test can prove a path never read, regenerated or destroyed the key.
private final class CountingKeyStore: ClipboardHistoryMasterKeyStoring,
    Sendable
{
    private struct State: Sendable {
        var key: Data?
        var loadCount = 0
        var createCount = 0
        var deleteCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(key: Data?) {
        state = OSAllocatedUnfairLock(initialState: State(key: key))
    }

    var loadCount: Int { state.withLock { $0.loadCount } }
    var createCount: Int { state.withLock { $0.createCount } }
    var deleteCount: Int { state.withLock { $0.deleteCount } }

    func load() -> ClipboardHistoryMasterKeyResult {
        let key = state.withLock { state -> Data? in
            state.loadCount += 1
            return state.key
        }
        guard let key else { return .missing }
        return .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        state.withLock { state in
            state.createCount += 1
            state.key = key
        }
        return .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        state.withLock { state in
            state.deleteCount += 1
            state.key = nil
        }
        return .missing
    }
}

/// A Keychain that is locked for this launch.
private final class LockedKeyStore: ClipboardHistoryMasterKeyStoring, Sendable {
    func load() -> ClipboardHistoryMasterKeyResult { .locked }
    func create() -> ClipboardHistoryMasterKeyResult { .locked }
    func delete() -> ClipboardHistoryMasterKeyResult { .locked }
}

/// Far longer than any child process here takes to answer or to exit once
/// told to; it only turns a stuck child into a failed test instead of a hung
/// run.
private let childProcessLimit: TimeInterval = 60

/// Whether `handle` has output to read, or has reached its end, before
/// `deadline`. A read from a child's pipe blocks until the child writes or
/// exits, so a child that stops answering would otherwise hang the run.
private func hasOutput(_ handle: FileHandle, before deadline: Date) -> Bool {
    var descriptor = pollfd(
        fd: handle.fileDescriptor,
        events: Int16(POLLIN),
        revents: 0
    )
    var ready: Int32
    repeat {
        let timeLeft = max(0, deadline.timeIntervalSinceNow)
        ready = poll(&descriptor, 1, Int32(timeLeft * 1_000))
    } while ready < 0 && errno == EINTR
    return ready > 0
}

/// Tells when a child process has exited. `Process.waitUntilExit()` waits by
/// running the calling thread's run loop, while Foundation reports the exit
/// through the thread that launched the child: an async test that resumed on
/// another thread after an `await` can wait there forever, long after the
/// child is gone. The termination handler runs on a queue of its own, so any
/// thread can wait for it.
private final class ProcessExit: Sendable {
    private let exited = DispatchSemaphore(value: 0)

    /// Installs the termination handler, so it must come before
    /// `process.run()`.
    init(of process: Process) {
        process.terminationHandler = { [exited] _ in exited.signal() }
    }

    /// Whether the child exited within `childProcessLimit`. Once it has,
    /// every later call answers at once.
    func wait() -> Bool {
        let deadline = DispatchTime.now() + childProcessLimit
        guard exited.wait(timeout: deadline) == .success else {
            return false
        }
        exited.signal()
        return true
    }
}

/// A real SQLite connection held open by another process, the way a still
/// running older release holds its store.
private final class ForeignConnection {
    let pid: pid_t
    private let process: Process
    private let exit: ProcessExit
    private let input: Pipe
    private var isOpen = true

    init(database: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // An error answers on the same pipe, so a failed query cannot leave
        // the read below waiting forever.
        process.standardError = output
        let exit = ProcessExit(of: process)
        try process.run()
        // The answer arrives only after the connection has opened the WAL
        // index, whose lock is what the move looks for.
        input.fileHandleForWriting.write(
            Data("SELECT count(*) FROM t;\n".utf8)
        )
        _ = output.fileHandleForReading.availableData
        self.process = process
        self.exit = exit
        self.input = input
        pid = process.processIdentifier
    }

    /// Returns once `sqlite3` has exited, and with it the connection.
    func close() {
        guard isOpen else { return }
        isOpen = false
        input.fileHandleForWriting.closeFile()
        guard exit.wait() else {
            process.terminate()
            return XCTFail("sqlite3 did not exit after its input closed")
        }
    }
}

/// Another running copy of AnyDoor with a store open: this test bundle run
/// again in a child process, where `testHoldStoreOpenAsAnotherProcess` opens
/// the store with a real module and keeps it open until told to quit.
private final class StoreHolderProcess {
    static let storeRootEnvironment = "ANYDOOR_STORE_RELOCATION_HOLDER_ROOT"
    static let readyLine = "STORE HOLDER READY"
    static let closedLine = "STORE HOLDER CLOSED"

    struct Failure: Error, CustomStringConvertible {
        var reason = "stopped early"
        let transcript: String

        var description: String {
            "The store holder process \(reason):\n\(transcript)"
        }
    }

    let pid: pid_t
    private let process: Process
    private let exit: ProcessExit
    private let input: Pipe
    private let output: Pipe
    private var transcript = ""

    /// Returns once the child has the store open.
    init(holding storeRoot: URL, testBundle: URL) throws {
        let process = Process()
        process.executableURL = URL(
            fileURLWithPath: ProcessInfo.processInfo.arguments[0]
        ).resolvingSymlinksInPath()
        process.arguments = [
            "-XCTest",
            "ClipboardHistoryStoreRelocationTests/"
                + "testHoldStoreOpenAsAnotherProcess",
            testBundle.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.storeRootEnvironment] = storeRoot.path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let exit = ProcessExit(of: process)
        try process.run()
        self.process = process
        self.exit = exit
        self.input = input
        self.output = output
        pid = process.processIdentifier
        let reader = output.fileHandleForReading
        let deadline = Date(timeIntervalSinceNow: childProcessLimit)
        while !transcript.contains(Self.readyLine) {
            guard hasOutput(reader, before: deadline) else {
                terminate()
                throw Failure(
                    reason: "did not open the store in time",
                    transcript: transcript
                )
            }
            let chunk = reader.availableData
            guard !chunk.isEmpty else {
                terminate()
                throw Failure(transcript: transcript)
            }
            transcript += String(decoding: chunk, as: UTF8.self)
        }
    }

    /// Makes the child capture `text`, close its store and exit.
    func captureAndQuit(_ text: String) throws {
        input.fileHandleForWriting.write(Data("\(text)\n".utf8))
        input.fileHandleForWriting.closeFile()
        let reader = output.fileHandleForReading
        let deadline = Date(timeIntervalSinceNow: childProcessLimit)
        while true {
            guard hasOutput(reader, before: deadline) else {
                terminate()
                throw Failure(
                    reason: "did not quit in time",
                    transcript: transcript
                )
            }
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            transcript += String(decoding: chunk, as: UTF8.self)
        }
        guard exit.wait() else {
            throw Failure(reason: "did not exit", transcript: transcript)
        }
        guard process.terminationStatus == 0,
            transcript.contains(Self.closedLine)
        else {
            throw Failure(transcript: transcript)
        }
    }

    /// Stops the child at once, as when a test ends early, and kills it
    /// outright if it does not exit.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        if !exit.wait() {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

private let captureSource = ClipboardHistoryCaptureSource(
    bundleIdentifier: "com.example.relocation",
    displayName: "Relocation"
)

private func tinyPNG() throws -> Data {
    guard
        let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    for x in 0..<8 {
        for y in 0..<8 {
            representation.setColor(
                NSColor(
                    deviceRed: CGFloat(x) / 8,
                    green: 0.2,
                    blue: CGFloat(y) / 8,
                    alpha: 1
                ),
                atX: x,
                y: y
            )
        }
    }
    guard
        let png = representation.representation(using: .png, properties: [:])
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

private func entryCount(of module: ClipboardHistoryModule) async throws -> Int {
    var total = 0
    var cursor: ClipboardHistoryCursor?
    repeat {
        let page = try await module.page(ClipboardHistoryQuery(), after: cursor)
        total += page.entries.count
        cursor = page.nextCursor
    } while cursor != nil
    return total
}

private func entryTexts(
    of module: ClipboardHistoryModule
) async throws -> [String] {
    var texts: [String] = []
    var cursor: ClipboardHistoryCursor?
    repeat {
        let page = try await module.page(ClipboardHistoryQuery(), after: cursor)
        texts += page.entries.compactMap(\.previewText)
        cursor = page.nextCursor
    } while cursor != nil
    return texts
}

private func inode(of url: URL) -> ino_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_ino
}

private func childNames(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path))
        ?? []).sorted()
}

private func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0
}

/// Relative path to contents for every file (directories map to empty data
/// under a trailing slash), so "nothing was deleted or rewritten" can be
/// asserted exactly.
private func inventory(_ root: URL) -> [String: Data] {
    var result: [String: Data] = [:]
    guard
        let enumerator = FileManager.default.enumerator(atPath: root.path)
    else {
        return result
    }
    for case let relative as String in enumerator {
        let url = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )
        else {
            continue
        }
        if isDirectory.boolValue {
            result[relative + "/"] = Data()
        } else {
            result[relative] = (try? Data(contentsOf: url)) ?? Data()
        }
    }
    return result
}

/// Allocated bytes of every regular file under `url`, the way storage usage
/// measures them.
private func allocatedBytes(_ url: URL) -> UInt64 {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return 0 }
    switch info.st_mode & mode_t(S_IFMT) {
    case mode_t(S_IFDIR):
        return (
            (try? FileManager.default.contentsOfDirectory(atPath: url.path))
                ?? []
        ).reduce(0) { total, name in
            total + allocatedBytes(url.appendingPathComponent(name))
        }
    case mode_t(S_IFREG):
        return UInt64(max(info.st_blocks, 0)) * 512
    default:
        return 0
    }
}

private func restoreOwnerPermissions(_ url: URL) {
    _ = chmod(url.path, 0o700)
    for name in (try? FileManager.default.contentsOfDirectory(
        atPath: url.path
    )) ?? [] {
        let child = url.appendingPathComponent(name)
        var info = stat()
        if lstat(child.path, &info) == 0,
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        {
            restoreOwnerPermissions(child)
        }
    }
}
