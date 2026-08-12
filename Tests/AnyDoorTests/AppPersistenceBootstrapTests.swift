import Foundation
import SwiftData
import XCTest

@testable import AnyDoor

@MainActor
final class AppPersistenceBootstrapTests: XCTestCase {
    func testSnapshotSuccessOpensProductionStoreWithoutRelaunch()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("AnyDoor.store")
        var snapshotAttempts = 0
        var relaunchCount = 0
        let bootstrap = try AppPersistenceBootstrap.make(
            schema: Schema([KeyBinding.self]),
            storeURL: storeURL,
            prepareLegacySnapshot: {
                XCTAssertFalse(
                    FileManager.default.fileExists(atPath: storeURL.path)
                )
                snapshotAttempts += 1
            },
            requestRelaunch: {
                relaunchCount += 1
            }
        )

        XCTAssertFalse(bootstrap.isRecoveryMode)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: storeURL.path)
        )
        XCTAssertEqual(snapshotAttempts, 1)
        let preparation = try await bootstrap.migrationPreparation()
        XCTAssertEqual(preparation, .proceed)
        XCTAssertEqual(relaunchCount, 0)
    }

    func testSnapshotFailureUsesRecoveryContainerUntilRetryRelaunches()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("AnyDoor.store")
        var snapshotAttempts = 0
        var relaunchCount = 0
        let bootstrap = try AppPersistenceBootstrap.make(
            schema: Schema([KeyBinding.self]),
            storeURL: storeURL,
            prepareLegacySnapshot: {
                snapshotAttempts += 1
                if snapshotAttempts == 1 {
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            requestRelaunch: {
                relaunchCount += 1
            }
        )

        XCTAssertTrue(bootstrap.isRecoveryMode)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path)
        )
        XCTAssertEqual(snapshotAttempts, 1)

        let preparation = try await bootstrap.migrationPreparation()

        XCTAssertEqual(preparation, .suspendForRelaunch)
        XCTAssertEqual(snapshotAttempts, 2)
        XCTAssertEqual(relaunchCount, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path)
        )
    }

    func testRelaunchFailurePropagatesWithoutOpeningProductionStore()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("AnyDoor.store")
        var snapshotAttempts = 0
        let bootstrap = try AppPersistenceBootstrap.make(
            schema: Schema([KeyBinding.self]),
            storeURL: storeURL,
            prepareLegacySnapshot: {
                snapshotAttempts += 1
                if snapshotAttempts == 1 {
                    throw CocoaError(.fileWriteNoPermission)
                }
            },
            requestRelaunch: {
                throw CocoaError(.executableNotLoadable)
            }
        )
        do {
            _ = try await bootstrap.migrationPreparation()
            XCTFail("Expected relaunch failure")
        } catch {
            XCTAssertEqual(
                (error as? CocoaError)?.code,
                .executableNotLoadable
            )
        }
        XCTAssertEqual(snapshotAttempts, 2)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: storeURL.path)
        )
    }
}
