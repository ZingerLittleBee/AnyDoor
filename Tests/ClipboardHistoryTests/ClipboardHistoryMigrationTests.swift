import Foundation
import Security
import XCTest

@testable import ClipboardHistory

final class ClipboardHistoryMigrationTests: XCTestCase {
    func testMigrationPreservesLegacyRowsAndMapsKindsWithoutDerivedBackfill()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let source = ClipboardHistoryCaptureSource(
            bundleIdentifier: "com.example.source",
            displayName: "Source",
            provenance: .legacy
        )
        let imageName = "legacy-image.png"
        try fixture.writeLegacyPayload(
            named: imageName,
            data: try XCTUnwrap(
                Data(
                    base64Encoded:
                        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
                )
            )
        )
        let entries = [
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                kind: .text,
                text: "https://example.com",
                capturedAt: now.addingTimeInterval(-10),
                source: source,
                isFavorite: true,
                tagIDs: ["work"]
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                kind: .color,
                colorHex: "#AABBCC",
                capturedAt: now.addingTimeInterval(-20)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                kind: .qrCode,
                text: "mailto:person@example.com",
                capturedAt: now.addingTimeInterval(-30)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                kind: .ocr,
                text: "https://ocr.example",
                capturedAt: now.addingTimeInterval(-40)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                kind: .image,
                fileName: imageName,
                capturedAt: now.addingTimeInterval(-50)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                kind: .screenshot,
                fileName: imageName,
                capturedAt: now.addingTimeInterval(-60)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
                kind: .text,
                text: "duplicate",
                capturedAt: now.addingTimeInterval(-70)
            ),
            legacyEntry(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000008")!,
                kind: .text,
                text: "duplicate",
                capturedAt: now.addingTimeInterval(-80)
            ),
        ]
        let module = fixture.makeModule(now: now)

        let outcome = try await module.migrateLegacy(
            fixture.request(
                entries: entries,
                tags: [
                    ClipboardHistoryLegacyTag(id: "work", name: "Work"),
                    ClipboardHistoryLegacyTag(id: "later", name: "Later"),
                ],
                categoryOrder: [
                    "all", "kind:text", "tag:later", "favorites",
                    "tag:work", "tag:missing",
                ],
                retentionPeriod: .unlimited
            )
        )

        XCTAssertEqual(
            outcome,
            .published(
                ClipboardHistoryLegacyMigrationReport(
                    retainedEntryCount: 8,
                    omittedExpiredEntryCount: 0,
                    ownedPayloadCount: 2,
                    redundantLegacyPayloadCount: 0
                )
            )
        )
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id.value), entries.map(\.id))
        let byID = Dictionary(
            uniqueKeysWithValues: page.entries.map {
                ($0.id.value, $0)
            })
        XCTAssertEqual(
            byID[entries[0].id]?.facets,
            [.text, .link]
        )
        XCTAssertEqual(byID[entries[0].id]?.source, source)
        XCTAssertEqual(byID[entries[0].id]?.isFavorite, true)
        XCTAssertEqual(byID[entries[0].id]?.tagIDs, ["work"])
        XCTAssertEqual(byID[entries[1].id]?.facets, [.text, .color])
        XCTAssertEqual(byID[entries[2].id]?.facets, [.text, .qrCode])
        XCTAssertEqual(byID[entries[3].id]?.facets, [.text])
        XCTAssertEqual(byID[entries[4].id]?.facets, [.image])
        XCTAssertEqual(byID[entries[5].id]?.facets, [.image, .screenshot])
        let migratedTags = try await module.tagDefinitions()
        XCTAssertEqual(
            migratedTags,
            [
                ClipboardHistoryTagDefinition(
                    id: "later",
                    displayName: "Later"
                ),
                ClipboardHistoryTagDefinition(
                    id: "work",
                    displayName: "Work"
                ),
            ]
        )
        for entry in entries[4...5] {
            let diagnostics = try await module.derivedIndexingDiagnostics(
                for: ClipboardHistoryEntryID(entry.id)
            )
            XCTAssertEqual(diagnostics.jobs, [])
        }
        let duplicatePage = try await module.page(
            ClipboardHistoryQuery(text: "duplicate")
        )
        XCTAssertEqual(duplicatePage.entries.count, 2)
    }

    func testMigrationAppliesExpiryAndResetsRetentionForOrphanProtection()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let now = Date(timeIntervalSince1970: 5_000_000)
        let old = now.addingTimeInterval(-8 * 86_400)
        let expiredID = UUID()
        let favoriteID = UUID()
        let validTagID = UUID()
        let orphanID = UUID()
        let module = fixture.makeModule(now: now)

        let outcome = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: expiredID,
                        kind: .text,
                        text: "expired",
                        capturedAt: old
                    ),
                    legacyEntry(
                        id: favoriteID,
                        kind: .text,
                        text: "favorite",
                        capturedAt: old,
                        isFavorite: true
                    ),
                    legacyEntry(
                        id: validTagID,
                        kind: .text,
                        text: "valid tag",
                        capturedAt: old,
                        tagIDs: ["valid"]
                    ),
                    legacyEntry(
                        id: orphanID,
                        kind: .text,
                        text: "orphan",
                        capturedAt: old,
                        tagIDs: ["deleted"]
                    ),
                ],
                tags: [
                    ClipboardHistoryLegacyTag(id: "valid", name: "Valid")
                ],
                categoryOrder: ["tag:valid"],
                retentionPeriod: .sevenDays
            )
        )

        XCTAssertEqual(
            outcome,
            .published(
                ClipboardHistoryLegacyMigrationReport(
                    retainedEntryCount: 3,
                    omittedExpiredEntryCount: 1,
                    ownedPayloadCount: 0,
                    redundantLegacyPayloadCount: 0
                )
            )
        )
        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(
            Set(page.entries.map(\.id.value)),
            [favoriteID, validTagID, orphanID]
        )
        XCTAssertEqual(
            page.entries.first { $0.id.value == orphanID }?.tagIDs,
            []
        )
        let diagnostics = try await module.legacyMigrationDiagnostics()
        XCTAssertEqual(
            diagnostics.retentionStartByEntryID[orphanID],
            now
        )
        XCTAssertEqual(
            diagnostics.retentionStartByEntryID[validTagID],
            old
        )
    }

    func testCorruptOwnedImageNeverPublishesPartialStagingStore()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        try fixture.writeLegacyPayload(
            named: "corrupt.png",
            data: Data("not a png".utf8)
        )
        let module = fixture.makeModule()
        let request = fixture.request(
            entries: [
                legacyEntry(
                    kind: .text,
                    text: "must not publish",
                    capturedAt: fixture.now
                ),
                legacyEntry(
                    kind: .image,
                    fileName: "corrupt.png",
                    capturedAt: fixture.now.addingTimeInterval(-1)
                ),
            ]
        )

        do {
            _ = try await module.migrateLegacy(request)
            XCTFail("Expected corrupt legacy payload migration to fail")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .legacyMigrationFailed
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: fixture.legacyPayloadURL("corrupt.png")),
            Data("not a png".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.storeRoot
                    .appendingPathComponent("history.sqlite").path
            )
        )
    }

    func testMigrationPreservesLegacyRecencyOrderWhenTimestampsTie()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        ]
        let module = fixture.makeModule()

        _ = try await module.migrateLegacy(
            fixture.request(
                entries: ids.enumerated().map { index, id in
                    legacyEntry(
                        id: id,
                        kind: .text,
                        text: "same time \(index)",
                        capturedAt: fixture.now
                    )
                },
                retentionPeriod: .unlimited
            )
        )

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries.map(\.id.value), ids)
    }

    func testFileMigrationClassifiesEveryMemberAndBlocksPartialPaste()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let originals = fixture.root.appendingPathComponent("Originals")
        try FileManager.default.createDirectory(
            at: originals,
            withIntermediateDirectories: true
        )
        let equal = originals.appendingPathComponent("equal.txt")
        let changed = originals.appendingPathComponent("changed.txt")
        let missingOriginal = originals.appendingPathComponent("missing.txt")
        let missingCopy = originals.appendingPathComponent("copy-missing.txt")
        let doubleMissing = originals.appendingPathComponent("double.txt")
        try Data(repeating: 0x31, count: 200_000).write(to: equal)
        try Data("current changed".utf8).write(to: changed)
        try Data("current without captured bytes".utf8).write(
            to: missingCopy
        )
        try fixture.writeLegacyPayload(
            named: "equal-copy",
            data: Data(repeating: 0x31, count: 200_000)
        )
        try fixture.writeLegacyPayload(
            named: "changed-copy",
            data: Data("captured original".utf8)
        )
        try fixture.writeLegacyPayload(
            named: "missing-original-copy",
            data: Data("only retained copy".utf8)
        )
        let entryID = UUID()
        let module = fixture.makeModule()

        let outcome = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: "equal-copy",
                                originalURL: equal
                            ),
                            legacyFile(
                                storedName: "changed-copy",
                                originalURL: changed
                            ),
                            legacyFile(
                                storedName: "missing-original-copy",
                                originalURL: missingOriginal
                            ),
                            legacyFile(
                                storedName: "named-copy-is-missing",
                                originalURL: missingCopy
                            ),
                            legacyFile(
                                storedName: nil,
                                originalURL: doubleMissing
                            ),
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )

        XCTAssertEqual(
            outcome,
            .published(
                ClipboardHistoryLegacyMigrationReport(
                    retainedEntryCount: 1,
                    omittedExpiredEntryCount: 0,
                    ownedPayloadCount: 2,
                    redundantLegacyPayloadCount: 1
                )
            )
        )
        let diagnostics = try await module.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        XCTAssertEqual(
            diagnostics.members.map(\.state),
            [
                .ordinary,
                .legacyOwned,
                .legacyOwned,
                .legacyUnverified,
                .unavailable,
            ]
        )
        XCTAssertEqual(
            diagnostics.members.map(\.capturedPath),
            [equal, changed, missingOriginal, missingCopy, doubleMissing]
                .map(\.path)
        )
        XCTAssertEqual(
            diagnostics.maximumDigestReadSize,
            64 * 1_024
        )
        XCTAssertGreaterThan(diagnostics.digestReadCount, 2)

        let page = try await module.page(ClipboardHistoryQuery())
        XCTAssertEqual(page.entries[0].facets, [.file])
        for query in [
            "equal.txt",
            "changed.txt",
            "missing.txt",
            doubleMissing.path,
        ] {
            let matches = try await module.page(
                ClipboardHistoryQuery(text: query)
            )
            XCTAssertEqual(
                matches.entries.map(\.id.value),
                [entryID]
            )
        }
        do {
            _ = try await module.materialize(
                ClipboardHistoryMaterializationRequest(
                    entryID: ClipboardHistoryEntryID(entryID),
                    purpose: .normalPaste
                )
            )
            XCTFail("Expected mixed file collection paste to be blocked")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .fileCollectionRequiresRestore(
                    ClipboardHistoryEntryID(entryID),
                    ownedCount: 2,
                    unavailableCount: 1
                )
            )
        }
    }

    func testLegacyUnverifiedBookmarkStartsIdentityAtMigration()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let original = fixture.root.appendingPathComponent("unverified.txt")
        try Data("current bytes".utf8).write(to: original)
        let entryID = UUID()
        let module = fixture.makeModule()
        _ = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: "missing-copy",
                                originalURL: original
                            )
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )

        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                purpose: .normalPaste
            )
        )
        guard
            case .file(let reference) =
                materialized.items.first?.representations.first
        else {
            return XCTFail("Expected a materialized file reference")
        }
        XCTAssertEqual(reference.capturedPath, original.path)
        XCTAssertEqual(reference.displayName, original.lastPathComponent)
        XCTAssertEqual(
            reference.currentURL.resolvingSymlinksInPath(),
            original.resolvingSymlinksInPath()
        )
    }

    func testUnreadableFileSidesFollowContractAndSingleOwnedRestore()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let readableCurrent = fixture.root.appendingPathComponent(
            "readable-current.txt"
        )
        let unreadableCurrent = fixture.root.appendingPathComponent(
            "unreadable-current.txt"
        )
        try Data("current".utf8).write(to: readableCurrent)
        try Data("different current".utf8).write(to: unreadableCurrent)
        try fixture.writeLegacyPayload(
            named: "unreadable-copy",
            data: Data("captured".utf8)
        )
        try fixture.writeLegacyPayload(
            named: "readable-copy",
            data: Data("captured".utf8)
        )
        let unreadableCopy = fixture.legacyPayloadURL("unreadable-copy")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadableCopy.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: unreadableCurrent.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadableCopy.path
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unreadableCurrent.path
            )
        }
        let entryID = UUID()
        let module = fixture.makeModule()

        _ = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: "unreadable-copy",
                                originalURL: readableCurrent
                            ),
                            legacyFile(
                                storedName: "readable-copy",
                                originalURL: unreadableCurrent
                            ),
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )

        let migrated = try await module.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        XCTAssertEqual(
            migrated.members.map(\.state),
            [.legacyUnverified, .legacyOwned]
        )
        let restoreRoot = fixture.root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(
            at: restoreRoot,
            withIntermediateDirectories: true
        )
        let destination = restoreRoot.appendingPathComponent("restored.txt")
        let outcome = try await module.restoreLegacyOwnedFiles(
            ClipboardHistoryLegacyFileRestoreRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                destinations: [
                    ClipboardHistoryLegacyFileDestination(
                        memberID: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: 1,
                            memberIndex: 0
                        ),
                        url: destination
                    )
                ]
            )
        )
        XCTAssertEqual(outcome, .restored(memberCount: 1))
        XCTAssertEqual(
            try Data(contentsOf: destination),
            Data("captured".utf8)
        )
    }

    func testOwnedFileRestoreCommitsAllMembersAndPreservesIdentity()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let firstOriginal = fixture.root.appendingPathComponent("first.txt")
        let secondOriginal = fixture.root.appendingPathComponent("second.txt")
        try fixture.writeLegacyPayload(
            named: "first-copy",
            data: Data("first captured".utf8)
        )
        try fixture.writeLegacyPayload(
            named: "second-copy",
            data: Data("second captured".utf8)
        )
        let entryID = UUID()
        let module = fixture.makeModule()
        _ = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: "first-copy",
                                originalURL: firstOriginal
                            ),
                            legacyFile(
                                storedName: "second-copy",
                                originalURL: secondOriginal
                            ),
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )
        let before = try await module.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        let restoreRoot = fixture.root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(
            at: restoreRoot,
            withIntermediateDirectories: true
        )
        let firstDestination = restoreRoot.appendingPathComponent("one.txt")
        let secondDestination = restoreRoot.appendingPathComponent("two.txt")

        let outcome = try await module.restoreLegacyOwnedFiles(
            ClipboardHistoryLegacyFileRestoreRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                destinations: [
                    ClipboardHistoryLegacyFileDestination(
                        memberID: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: 1,
                            memberIndex: 0
                        ),
                        url: secondDestination
                    ),
                    ClipboardHistoryLegacyFileDestination(
                        memberID: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: 0,
                            memberIndex: 0
                        ),
                        url: firstDestination
                    ),
                ]
            )
        )

        XCTAssertEqual(outcome, .restored(memberCount: 2))
        XCTAssertEqual(
            try Data(contentsOf: firstDestination),
            Data("first captured".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: secondDestination),
            Data("second captured".utf8)
        )
        let after = try await module.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        XCTAssertEqual(after.members.map(\.state), [.ordinary, .ordinary])
        XCTAssertEqual(after.ownedPayloadCount, 0)
        XCTAssertEqual(after.duplicateFingerprint, before.duplicateFingerprint)
        XCTAssertEqual(
            after.members.map(\.capturedPath),
            [firstOriginal.path, secondOriginal.path]
        )
        let materialized = try await module.materialize(
            ClipboardHistoryMaterializationRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                purpose: .normalPaste
            )
        )
        XCTAssertEqual(
            materialized.items.compactMap {
                guard case .file(let value) = $0.representations.first else {
                    return nil
                }
                return value.currentURL.resolvingSymlinksInPath()
            },
            [
                firstDestination.resolvingSymlinksInPath(),
                secondDestination.resolvingSymlinksInPath(),
            ]
        )
        let repeatedOutcome = try await module.restoreLegacyOwnedFiles(
            ClipboardHistoryLegacyFileRestoreRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                destinations: [
                    ClipboardHistoryLegacyFileDestination(
                        memberID: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: 0,
                            memberIndex: 0
                        ),
                        url: firstDestination,
                        collisionPolicy: .reuseIfIdentical
                    ),
                    ClipboardHistoryLegacyFileDestination(
                        memberID: ClipboardHistoryLegacyFileMemberID(
                            itemIndex: 1,
                            memberIndex: 0
                        ),
                        url: secondDestination,
                        collisionPolicy: .reuseIfIdentical
                    ),
                ]
            )
        )
        XCTAssertEqual(repeatedOutcome, .alreadyRestored(memberCount: 2))
    }

    func testOwnedFileRestoreRollsBackHistoryAndRetriesAfterFailure()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let firstOriginal = fixture.root.appendingPathComponent("first.txt")
        let secondOriginal = fixture.root.appendingPathComponent("second.txt")
        try fixture.writeLegacyPayload(
            named: "first-copy",
            data: Data("first captured".utf8)
        )
        try fixture.writeLegacyPayload(
            named: "second-copy",
            data: Data("second captured".utf8)
        )
        let entryID = UUID()
        let failingModule = fixture.makeModule(
            faultInjector: ClipboardHistoryFaultInjector(
                points: [.databaseTransaction]
            )
        )
        _ = try await failingModule.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: "first-copy",
                                originalURL: firstOriginal
                            ),
                            legacyFile(
                                storedName: "second-copy",
                                originalURL: secondOriginal
                            ),
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )
        let restoreRoot = fixture.root.appendingPathComponent("Restored")
        try FileManager.default.createDirectory(
            at: restoreRoot,
            withIntermediateDirectories: true
        )
        let firstDestination = restoreRoot.appendingPathComponent("one.txt")
        let secondDestination = restoreRoot.appendingPathComponent("two.txt")
        let failedRequest = ClipboardHistoryLegacyFileRestoreRequest(
            entryID: ClipboardHistoryEntryID(entryID),
            destinations: [
                ClipboardHistoryLegacyFileDestination(
                    memberID: ClipboardHistoryLegacyFileMemberID(
                        itemIndex: 0,
                        memberIndex: 0
                    ),
                    url: firstDestination
                ),
                ClipboardHistoryLegacyFileDestination(
                    memberID: ClipboardHistoryLegacyFileMemberID(
                        itemIndex: 1,
                        memberIndex: 0
                    ),
                    url: secondDestination
                ),
            ]
        )

        do {
            _ = try await failingModule.restoreLegacyOwnedFiles(failedRequest)
            XCTFail("Expected database transaction failure")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .legacyFileRestoreFailed
            )
        }
        let failedState = try await failingModule.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        XCTAssertEqual(
            failedState.members.map(\.state),
            [.legacyOwned, .legacyOwned]
        )
        XCTAssertEqual(failedState.ownedPayloadCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstDestination.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: secondDestination.path)
        )

        let retryingModule = fixture.makeModule()
        let retryOutcome = try await retryingModule.restoreLegacyOwnedFiles(
            ClipboardHistoryLegacyFileRestoreRequest(
                entryID: ClipboardHistoryEntryID(entryID),
                destinations: failedRequest.destinations.map {
                    ClipboardHistoryLegacyFileDestination(
                        memberID: $0.memberID,
                        url: $0.url,
                        collisionPolicy: .reuseIfIdentical
                    )
                }
            )
        )
        XCTAssertEqual(retryOutcome, .restored(memberCount: 2))
        let restoredState = try await retryingModule.legacyFileDiagnostics(
            for: ClipboardHistoryEntryID(entryID)
        )
        XCTAssertEqual(
            restoredState.members.map(\.state),
            [.ordinary, .ordinary]
        )
    }

    func testMigrationPublicationCrashBoundariesAreRetrySafe()
        async throws
    {
        for point in [
            ClipboardHistoryFaultPoint.legacyMigrationBeforePublication,
            .legacyMigrationAfterPublication,
        ] {
            let fixture = try LegacyMigrationFixture()
            let entry = legacyEntry(
                kind: .text,
                text: "survives publication fault",
                capturedAt: fixture.now
            )
            let request = fixture.request(
                entries: [entry],
                retentionPeriod: .unlimited
            )
            let failingModule = fixture.makeModule(
                faultInjector: ClipboardHistoryFaultInjector(
                    points: [point]
                )
            )

            do {
                _ = try await failingModule.migrateLegacy(request)
                XCTFail("Expected migration publication fault")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardHistoryModuleError,
                    .legacyMigrationFailed
                )
            }

            let retryingModule = fixture.makeModule()
            let outcome = try await retryingModule.migrateLegacy(request)
            switch point {
            case .legacyMigrationBeforePublication:
                guard case .published = outcome else {
                    return XCTFail("Expected an unpublished stage to rebuild")
                }
            case .legacyMigrationAfterPublication:
                guard case .alreadyPublished = outcome else {
                    return XCTFail("Expected published store discovery")
                }
            default:
                XCTFail("Unexpected fault point")
            }
            let page = try await retryingModule.page(
                ClipboardHistoryQuery()
            )
            XCTAssertEqual(page.entries.map(\.id.value), [entry.id])
        }
    }

    func testLegacyCleanupRequiresProofAndRecoversAcrossDeleteFaults()
        async throws
    {
        for point in [
            ClipboardHistoryFaultPoint.legacyCleanupBeforeDelete,
            .legacyCleanupAfterDelete,
        ] {
            let fixture = try LegacyMigrationFixture()
            let payloadName = "owned-copy"
            try fixture.writeLegacyPayload(
                named: payloadName,
                data: Data("captured bytes".utf8)
            )
            let module = fixture.makeModule(
                faultInjector: ClipboardHistoryFaultInjector(
                    points: [point]
                )
            )
            _ = try await module.migrateLegacy(
                fixture.request(
                    entries: [
                        legacyEntry(
                            kind: .file,
                            capturedAt: fixture.now,
                            files: [
                                legacyFile(
                                    storedName: payloadName,
                                    originalURL: fixture.root
                                        .appendingPathComponent("missing.txt")
                                )
                            ]
                        )
                    ],
                    retentionPeriod: .unlimited
                )
            )

            do {
                _ = try await module.cleanupLegacyPayloads(
                    in: fixture.legacyPayloadRoot
                )
                XCTFail("Expected cleanup fault")
            } catch {
                XCTAssertEqual(
                    error as? ClipboardHistoryModuleError,
                    .legacyCleanupFailed
                )
            }
            XCTAssertEqual(
                FileManager.default.fileExists(
                    atPath: fixture.legacyPayloadURL(payloadName).path
                ),
                point == .legacyCleanupBeforeDelete
            )

            let retryingModule = fixture.makeModule()
            let report = try await retryingModule.cleanupLegacyPayloads(
                in: fixture.legacyPayloadRoot
            )
            XCTAssertEqual(report.pendingPayloadCount, 0)
            XCTAssertTrue(report.canDeleteLegacyRows)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.legacyPayloadURL(payloadName).path
                )
            )
        }
    }

    func testLegacyCleanupRetainsPlaintextWhenRedundancyProofDrifts()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let original = fixture.root.appendingPathComponent("equal.txt")
        let payloadName = "equal-copy"
        try Data("equal at migration".utf8).write(to: original)
        try fixture.writeLegacyPayload(
            named: payloadName,
            data: Data("equal at migration".utf8)
        )
        let module = fixture.makeModule()
        _ = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: payloadName,
                                originalURL: original
                            )
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )
        try Data("changed after migration".utf8).write(to: original)

        do {
            _ = try await module.cleanupLegacyPayloads(
                in: fixture.legacyPayloadRoot
            )
            XCTFail("Expected proof drift to block cleanup")
        } catch {
            XCTAssertEqual(
                error as? ClipboardHistoryModuleError,
                .legacyCleanupFailed
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.legacyPayloadURL(payloadName).path
            )
        )
    }

    func testPublishedCleanupProofSurvivesNewHistoryDeletion()
        async throws
    {
        let fixture = try LegacyMigrationFixture()
        let payloadName = "owned-copy"
        try fixture.writeLegacyPayload(
            named: payloadName,
            data: Data("captured bytes".utf8)
        )
        let entryID = UUID()
        let module = fixture.makeModule()
        _ = try await module.migrateLegacy(
            fixture.request(
                entries: [
                    legacyEntry(
                        id: entryID,
                        kind: .file,
                        capturedAt: fixture.now,
                        files: [
                            legacyFile(
                                storedName: payloadName,
                                originalURL: fixture.root
                                    .appendingPathComponent("missing.txt")
                            )
                        ]
                    )
                ],
                retentionPeriod: .unlimited
            )
        )
        let deletion = try await module.apply(
            .delete(ClipboardHistoryEntryID(entryID))
        )
        XCTAssertEqual(deletion, .deleted)

        let report = try await module.cleanupLegacyPayloads(
            in: fixture.legacyPayloadRoot
        )

        XCTAssertEqual(report.removedPayloadCount, 1)
        XCTAssertEqual(report.pendingPayloadCount, 0)
        XCTAssertTrue(report.canDeleteLegacyRows)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.legacyPayloadURL(payloadName).path
            )
        )
    }
}

private final class LegacyMigrationFixture {
    let root: URL
    let storeRoot: URL
    let legacyPayloadRoot: URL
    let now = Date(timeIntervalSince1970: 8_000_000)
    private let keyStore = LegacyMigrationKeyStore()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AnyDoor-ClipboardLegacyMigration-\(UUID().uuidString)"
        )
        storeRoot = root.appendingPathComponent("ClipboardHistory")
        legacyPayloadRoot = root.appendingPathComponent("LegacyPayloads")
        try FileManager.default.createDirectory(
            at: legacyPayloadRoot,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func makeModule(
        now: Date? = nil,
        faultInjector: ClipboardHistoryFaultInjector =
            ClipboardHistoryFaultInjector()
    ) -> ClipboardHistoryModule {
        let currentDate = now ?? self.now
        return ClipboardHistoryModule(
            testingStoreRoot: storeRoot,
            keyStore: keyStore,
            faultInjector: faultInjector,
            now: { currentDate }
        )
    }

    func request(
        entries: [ClipboardHistoryLegacyEntry],
        tags: [ClipboardHistoryLegacyTag] = [],
        categoryOrder: [String] = [],
        retentionPeriod: ClipboardHistoryRetentionPeriod = .thirtyDays
    ) -> ClipboardHistoryLegacyMigrationRequest {
        ClipboardHistoryLegacyMigrationRequest(
            transfer: ClipboardHistoryLegacyTransfer(
                version: 1,
                entries: entries,
                tags: tags,
                categoryOrder: categoryOrder,
                retentionPeriod: retentionPeriod
            ),
            payloadDirectory: legacyPayloadRoot
        )
    }

    func writeLegacyPayload(named name: String, data: Data) throws {
        try data.write(to: legacyPayloadURL(name))
    }

    func legacyPayloadURL(_ name: String) -> URL {
        legacyPayloadRoot.appendingPathComponent(name)
    }
}

private final class LegacyMigrationKeyStore:
    ClipboardHistoryMasterKeyStoring,
    Sendable
{
    private let key = Data(repeating: 0x71, count: 32)

    func load() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func create() -> ClipboardHistoryMasterKeyResult {
        .key(key)
    }

    func delete() -> ClipboardHistoryMasterKeyResult {
        .missing
    }
}

private func legacyEntry(
    id: UUID = UUID(),
    kind: ClipboardHistoryLegacyKind,
    text: String? = nil,
    fileName: String? = nil,
    colorHex: String? = nil,
    capturedAt: Date,
    richData: Data? = nil,
    richType: String? = nil,
    source: ClipboardHistoryCaptureSource = .unknown,
    isFavorite: Bool = false,
    tagIDs: [String] = [],
    files: [ClipboardHistoryLegacyFileMember] = []
) -> ClipboardHistoryLegacyEntry {
    ClipboardHistoryLegacyEntry(
        id: id,
        kind: kind,
        text: text,
        fileName: fileName,
        colorHex: colorHex,
        previewText: text ?? colorHex,
        capturedAt: capturedAt,
        richData: richData,
        richType: richType,
        source: source,
        isFavorite: isFavorite,
        tagIDs: tagIDs,
        files: files
    )
}

private func legacyFile(
    storedName: String?,
    originalURL: URL
) -> ClipboardHistoryLegacyFileMember {
    ClipboardHistoryLegacyFileMember(
        storedName: storedName,
        originalName: originalURL.lastPathComponent,
        originalPath: originalURL.path
    )
}
