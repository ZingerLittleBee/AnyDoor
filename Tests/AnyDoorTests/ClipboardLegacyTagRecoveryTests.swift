import ClipboardHistoryTestSupport
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardLegacyTagRecoveryTests: XCTestCase {
    func testMalformedLegacyTagsDoNotBlockUsableHistoryOrChangeMemberships() async throws {
        let fixture = try RecoveryFixture(testCase: self)
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("retained history")))
        let tag = try await fixture.module.createTagDefinition(named: "Authoritative", assigningTo: entry.entryID).definition
        let original = "[malformed private tag sentinel"
        fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
        let lifecycle = fixture.lifecycle()
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let definitions = try await fixture.module.tagDefinitions()
        let entries = try await fixture.module.page(.init()).entries
        XCTAssertEqual(definitions, [tag])
        XCTAssertEqual(entries.first?.tagIDs, [tag.id])
        XCTAssertEqual(lifecycle.legacyTagRecoveryFormat, .json)
        let recovery = try await fixture.module.legacyTagRecovery()
        XCTAssertEqual(recovery, .init(format: .json, data: Data(original.utf8)))
        try assertNoPlaintext(original, in: fixture.directory)
        await lifecycle.stop()
        try await fixture.module.closeStoreForTesting()

        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)))
        fixture.defaults.set("[{\"id\":\"stale\",\"name\":\"Do not resurrect\"}]", forKey: ClipboardHistoryPortableKeys.customTags)
        let restarted = fixture.lifecycle(module: reopened)
        restarted.start()
        await restarted.awaitCurrentOperationForTesting()
        XCTAssertEqual(restarted.state, .ready)
        XCTAssertEqual(restarted.legacyTagRecoveryFormat, .json)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let retained = try await reopened.tagDefinitions()
        let retainedEntries = try await reopened.page(.init()).entries
        XCTAssertEqual(retained, [tag])
        XCTAssertEqual(retainedEntries.first?.tagIDs, [tag.id])
        try assertNoPlaintext(original, in: fixture.directory)
        let destination = fixture.directory.appendingPathComponent("requested-recovery.json")
        try await restarted.exportLegacyTagRecovery(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data(original.utf8))
        await restarted.stop()
    }

    func testWrongTypedLegacyPreferencePreservesItsPropertyListRepresentation() async throws {
        let fixture = try RecoveryFixture(testCase: self)
        let original: NSDictionary = [
            "name": "wrong typed private tag sentinel",
            "bytes": Data([0, 255, 17]),
            "date": Date(timeIntervalSince1970: 123456789),
            "values": [true, 7, 2.5] as [Any],
        ]
        fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
        let lifecycle = fixture.lifecycle()
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()

        XCTAssertEqual(lifecycle.state, .ready)
        XCTAssertEqual(lifecycle.legacyTagRecoveryFormat, .propertyList)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        try assertNoPlaintext("wrong typed private tag sentinel", in: fixture.directory)
        let destination = fixture.directory.appendingPathComponent("requested-recovery.plist")
        try await lifecycle.exportLegacyTagRecovery(to: destination)
        let restored = try PropertyListSerialization.propertyList(from: Data(contentsOf: destination), format: nil) as? NSDictionary
        XCTAssertEqual(restored, original)
        await lifecycle.stop()
    }

    func testInvalidTagArraysPreserveTheWholeOriginalWithoutPartialImport() async throws {
        let invalidValues = [
            "",
            #"[{"id":"new","name":"Readable"},{"id":"new","name":"Duplicate"}]"#,
            #"[{"id":"new","name":"Readable"},{"id":"","name":"Empty ID"}]"#,
            #"[{"id":"new","name":"Readable"},{"id":"blank","name":" \n\t"}]"#,
        ]
        for original in invalidValues {
            let fixture = try RecoveryFixture(testCase: self)
            let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("existing history")))
            let tag = try await fixture.module.createTagDefinition(named: "Current", assigningTo: entry.entryID).definition
            fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
            let lifecycle = fixture.lifecycle()
            lifecycle.start()
            await lifecycle.awaitCurrentOperationForTesting()

            XCTAssertEqual(lifecycle.state, .ready)
            XCTAssertEqual(lifecycle.legacyTagRecoveryFormat, .json)
            XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
            let definitions = try await fixture.module.tagDefinitions()
            let entries = try await fixture.module.page(.init()).entries
            let recovery = try await fixture.module.legacyTagRecovery()
            XCTAssertEqual(definitions, [tag])
            XCTAssertEqual(entries.first?.tagIDs, [tag.id])
            XCTAssertEqual(recovery?.data, Data(original.utf8))
            await lifecycle.stop()
        }
    }

    func testNonStringScalarAndCollectionPreferencesRemainRecoverable() async throws {
        let originals: [Any] = [true, 42, 2.5, Data([0, 255]), Date(timeIntervalSince1970: 123456789), ["unreadable", "tags"]]
        for original in originals {
            let fixture = try RecoveryFixture(testCase: self)
            fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
            let lifecycle = fixture.lifecycle()
            lifecycle.start()
            await lifecycle.awaitCurrentOperationForTesting()

            XCTAssertEqual(lifecycle.state, .ready)
            XCTAssertEqual(lifecycle.legacyTagRecoveryFormat, .propertyList)
            XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
            let recovery = try await fixture.module.legacyTagRecovery()
            let data = try XCTUnwrap(recovery?.data)
            let restored = try PropertyListSerialization.propertyList(from: data, format: nil)
            XCTAssertEqual(["value": restored] as NSDictionary, ["value": original] as NSDictionary)
            await lifecycle.stop()
        }
    }

    func testArchiveTransactionFailureRetainsOriginalAndRetriesAfterRestart() async throws {
        let fixture = try RecoveryFixture(testCase: self)
        let entry = try await fixture.module.capture(.init(source: .unknown, content: .text("preserved through failure")))
        let tag = try await fixture.module.createTagDefinition(named: "Current", assigningTo: entry.entryID).definition
        try await fixture.module.closeStoreForTesting()
        let failing = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32), faultInjector: .init(points: [.databaseTransaction])))
        let original = "{unreadable private archive sentinel"
        fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
        let failed = fixture.lifecycle(module: failing)
        failed.start()
        await failed.awaitCurrentOperationForTesting()

        XCTAssertEqual(failed.state, .migrationFailed)
        XCTAssertNil(failed.legacyTagRecoveryFormat)
        XCTAssertEqual(fixture.defaults.string(forKey: ClipboardHistoryPortableKeys.customTags), original)
        let failedRecovery = try await failing.legacyTagRecovery()
        let failedDefinitions = try await failing.tagDefinitions()
        let failedEntries = try await failing.page(.init()).entries
        XCTAssertNil(failedRecovery, "The archive and retirement marker must roll back together")
        XCTAssertEqual(failedDefinitions, [tag])
        XCTAssertEqual(failedEntries.first?.tagIDs, [tag.id])
        await failed.stop()
        try await failing.closeStoreForTesting()

        let reopened = try trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: fixture.directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32)))
        let retry = fixture.lifecycle(module: reopened)
        retry.start()
        await retry.awaitCurrentOperationForTesting()
        XCTAssertEqual(retry.state, .ready)
        XCTAssertEqual(retry.legacyTagRecoveryFormat, .json)
        XCTAssertNil(fixture.defaults.object(forKey: ClipboardHistoryPortableKeys.customTags))
        let recovered = try await reopened.legacyTagRecovery()
        let definitions = try await reopened.tagDefinitions()
        let entries = try await reopened.page(.init()).entries
        XCTAssertEqual(recovered?.data, Data(original.utf8))
        XCTAssertEqual(definitions, [tag])
        XCTAssertEqual(entries.first?.tagIDs, [tag.id])
        try assertNoPlaintext(original, in: fixture.directory)
        await retry.stop()
    }

    func testFailedExplicitExportKeepsEncryptedRecoveryAvailable() async throws {
        let fixture = try RecoveryFixture(testCase: self)
        let original = "original private export sentinel"
        fixture.defaults.set(original, forKey: ClipboardHistoryPortableKeys.customTags)
        let lifecycle = fixture.lifecycle()
        lifecycle.start()
        await lifecycle.awaitCurrentOperationForTesting()
        XCTAssertEqual(lifecycle.state, .ready)
        do {
            try await lifecycle.exportLegacyTagRecovery(to: fixture.directory.appendingPathComponent("missing/recovery.json"))
            XCTFail("Export must report an unwritable destination")
        } catch {}
        XCTAssertEqual(lifecycle.legacyTagRecoveryFormat, .json)
        let recovery = try await fixture.module.legacyTagRecovery()
        XCTAssertEqual(recovery?.data, Data(original.utf8))
        try assertNoPlaintext(original, in: fixture.directory)
        let destination = fixture.directory.appendingPathComponent("requested-recovery.json")
        try await lifecycle.exportLegacyTagRecovery(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data(original.utf8))
        await lifecycle.stop()
    }

    private func assertNoPlaintext(_ sentinel: String, in directory: URL) throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            XCTAssertNil(try Data(contentsOf: file).range(of: Data(sentinel.utf8)), file.lastPathComponent)
        }
    }
}

private struct RecoveryFixture {
    let directory: URL
    let defaults: UserDefaults
    let module: ClipboardHistoryModule

    @MainActor
    init(testCase: XCTestCase, faultInjector: ClipboardHistoryFaultInjector = .init()) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.removeClipboardHistoryDirectoryAfterTest(directory)
        defaults = testCase.makeTemporaryDefaults()
        defaults.set(false, forKey: ClipboardPreferences.monitoringKey)
        module = try testCase.trackClipboardHistoryModule(ClipboardHistoryModule(
            testingDatabaseURL: directory.appendingPathComponent("history.sqlite"),
            databaseKey: Data(repeating: 0x42, count: 32), faultInjector: faultInjector))
    }

    @MainActor
    func lifecycle(module: ClipboardHistoryModule? = nil) -> ClipboardHistoryLifecycle {
        ClipboardHistoryLifecycle(module: module ?? self.module, defaults: defaults, migrationRequest: nil)
    }
}
