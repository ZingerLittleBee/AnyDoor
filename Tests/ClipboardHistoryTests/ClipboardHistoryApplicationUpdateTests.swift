import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testApplicationSavedChangesRemainBidirectionalAndUnknownSelfReplacementNeedsReassociation() async throws {
        let identifier = "dev.bybee.AnyDoor.tests.self-update.\(UUID())"
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            _ = try ClipboardApplicationTestFixture.create(at: root, bundleIdentifier: identifier,
                resource: "initial package", signed: false)
        }, sourceName: "Self Updating.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let resource = "Contents/Resources/Resource.txt"
        try Data("saved at original location".utf8).write(to: fixture.original.appendingPathComponent(resource))
        try await eventually {
            let originals = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
            return originals.first?.baseVersionID != working.baseVersionID
        }
        await fixture.sender.retrySync()
        await fixture.receiver.retrySync()
        let firstLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let first = try XCTUnwrap(firstLocations.first)
        let firstPlan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: first.id, expectedRevision: first.revision))
        try await fixture.receiver.applyApplicationUpdate(firstPlan)

        try Data("saved after a known application swap".utf8).write(to: working.url.appendingPathComponent(resource))
        try await eventually {
            let received = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
            return received.first?.baseVersionID != firstPlan.versionID
        }
        await fixture.receiver.retrySync()
        await fixture.sender.retrySync()
        let originals = try await fixture.sender.linkedFileLocations(for: fixture.entryID)
        let original = try XCTUnwrap(originals.first)
        let reverse = try await fixture.sender.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: original.id, expectedRevision: original.revision))
        try await fixture.sender.applyApplicationUpdate(reverse)
        XCTAssertEqual(try Data(contentsOf: fixture.original.appendingPathComponent(resource)), Data("saved after a known application swap".utf8))

        try await fixture.receiver.setSyncEnabled(false)
        let unknown = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Self Update Candidate.app"),
            bundleIdentifier: identifier, resource: "external replacement", signed: false)
        _ = try FileManager.default.replaceItemAt(working.url, withItemAt: unknown.url)
        try await fixture.receiver.setSyncEnabled(true)
        let uncertainLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let uncertain = try XCTUnwrap(uncertainLocations.first)
        XCTAssertEqual(uncertain.state, .identityUncertain)
        XCTAssertEqual(uncertain.baseVersionID, reverse.versionID)
        let rebound = try await fixture.receiver.reassociateFileLocation(.init(selection: .init(entryID: fixture.entryID,
            locationID: uncertain.id, expectedRevision: uncertain.revision), url: working.url))
        XCTAssertEqual(rebound.id, working.id)
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent(resource)), Data("external replacement".utf8))
    }

    @MainActor
    func testApplicationLaunchedDuringPreparationIsRefusedAtFinalExchange() async throws {
        let barrier = LinkedReplacementBarrier()
        let identifier = "dev.bybee.AnyDoor.tests.late-launch.\(UUID())"
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        }, prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            _ = try ClipboardApplicationTestFixture.create(at: root, bundleIdentifier: identifier, resource: "old package")
        }, sourceName: "Late Launch.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let old = ClipboardApplicationTestFixture(url: working.url)
        let baseline = try old.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let update = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Update.app"),
            bundleIdentifier: identifier, resource: "complete update")
        try FileManager.default.removeItem(at: fixture.original.appendingPathComponent("Contents"))
        try FileManager.default.copyItem(at: update.url.appendingPathComponent("Contents"), to: fixture.original.appendingPathComponent("Contents"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(displayed.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(plan.state, .ready)
        let apply = Task { try await fixture.receiver.applyApplicationUpdate(plan) }
        defer { barrier.release() }
        try await eventually { barrier.isWaiting }
        let running = try await old.launch()
        addTeardownBlock { try await running.stop() }
        barrier.release()
        do { try await apply.value; XCTFail("A launch after preparation must revoke replacement") }
        catch ClipboardHistoryApplicationUpdateError.running { }
        XCTAssertEqual(try old.contentsSnapshot(), baseline)
        try old.verifySignature()
        try await running.stop()
    }

    @MainActor
    func testNestedApplicationNeedsExplicitUpdateAndIgnoresIndependentLinkedCopy() async throws {
        let identifier = "dev.bybee.AnyDoor.tests.nested-application.\(UUID())"
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = try ClipboardApplicationTestFixture.create(at: root.appendingPathComponent("Inner.app"),
                bundleIdentifier: identifier, resource: "old nested package")
            let external = root.deletingLastPathComponent().appendingPathComponent("Independent.app")
            _ = try ClipboardApplicationTestFixture.create(at: external, bundleIdentifier: identifier, resource: "independent package")
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("External.app"), withDestinationURL: external)
        }, sourceName: "Ordinary Folder")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let old = ClipboardApplicationTestFixture(url: working.url.appendingPathComponent("Inner.app"))
        let baseline = try old.contentsSnapshot()
        let independent = ClipboardApplicationTestFixture(url: fixture.root.appendingPathComponent("Independent.app"))
        let independentSnapshot = try independent.contentsSnapshot()
        let otherProcess = try await independent.launch()
        addTeardownBlock { try await otherProcess.stop() }
        let running = try await old.launch()
        addTeardownBlock { try await running.stop() }
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let update = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Update.app"),
            bundleIdentifier: identifier, resource: "new nested package")
        let source = fixture.original.appendingPathComponent("Inner.app/Contents")
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: update.url.appendingPathComponent("Contents"), to: source)
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        XCTAssertEqual(try old.contentsSnapshot(), baseline, "A folder exchange would also replace its running application")
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(displayed.first)
        XCTAssertNotNil(current.applicationUpdateVersionID)
        let blocked = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(blocked.state, .running)
        try await running.stop()
        let ready = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(ready.state, .ready, "Another copy with the same bundle ID is not the associated application")
        try await fixture.receiver.applyApplicationUpdate(ready)
        XCTAssertEqual(try old.contentsSnapshot(), try update.contentsSnapshot())
        try old.verifySignature()
        XCTAssertTrue(otherProcess.isRunning)
        XCTAssertEqual(try independent.contentsSnapshot(), independentSnapshot, "An external symbolic link never grants replacement authority")
    }

    @MainActor
    func testExplicitApplicationUpdatePreservesItsSignedCompletePackage() async throws {
        let bundleID = "dev.bybee.AnyDoor.tests.application.\(UUID().uuidString)"
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            _ = try ClipboardApplicationTestFixture.create(at: root, bundleIdentifier: bundleID, resource: "previous signed resource")
        }, sourceName: "Linked Fixture.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let old = ClipboardApplicationTestFixture(url: working.url)
        try old.verifySignature()
        let oldSnapshot = try old.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let updated = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Update.app"),
            bundleIdentifier: bundleID, resource: "new signed resource")
        try FileManager.default.removeItem(at: fixture.original.appendingPathComponent("Contents"))
        try FileManager.default.copyItem(at: updated.url.appendingPathComponent("Contents"), to: fixture.original.appendingPathComponent("Contents"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        XCTAssertEqual(try old.contentsSnapshot(), oldSnapshot)
        let readyLocations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let displayed = try XCTUnwrap(readyLocations.first)

        let running = try await old.launch()
        addTeardownBlock { try await running.stop() }
        let refused = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: displayed.id, expectedRevision: displayed.revision))
        XCTAssertEqual(refused.state, .running)
        do {
            try await fixture.receiver.applyApplicationUpdate(refused)
            XCTFail("A running associated application must not be replaced")
        } catch ClipboardHistoryApplicationUpdateError.running { }
        XCTAssertEqual(try old.contentsSnapshot(), oldSnapshot)
        try await running.stop()

        let refreshed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let stopped = try XCTUnwrap(refreshed.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: stopped.id, expectedRevision: stopped.revision))
        XCTAssertEqual(plan.state, .ready)
        try await fixture.receiver.applyApplicationUpdate(plan)

        try old.verifySignature()
        XCTAssertEqual(try old.contentsSnapshot(), try updated.contentsSnapshot())
        let applied = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(applied.first?.id, working.id)
        XCTAssertEqual(applied.first?.baseVersionID, plan.versionID)
    }

    @MainActor
    func testApplicationVersionDownloadsWithoutReplacingItsLinkedLocation() async throws {
        let fixture = try await makeLinkedFixture(prepareSource: { root in
            try FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let plist: [String: String] = ["CFBundlePackageType": "APPL", "CFBundleIdentifier": "dev.bybee.AnyDoor.tests.update-boundary"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
            try Data("previous application resource".utf8).write(to: root.appendingPathComponent("Contents/Resources/value.txt"))
        })
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("downloaded application update".utf8).write(to: fixture.original.appendingPathComponent("Contents/Resources/value.txt"))

        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)

        let page = try await fixture.receiver.page(.init())
        let update = try XCTUnwrap(page.entries.first?.syncFiles.first)
        XCTAssertNotEqual(update.versionID, working.baseVersionID)
        XCTAssertEqual(update.availableVersionID, working.baseVersionID, "Normal actions still use the installed version")
        let downloaded = await fixture.cloud.downloadedFileVersions()
        XCTAssertTrue(downloaded.contains(update.versionID), "The update downloads without authorizing replacement")
        XCTAssertEqual(try Data(contentsOf: working.url.appendingPathComponent("Contents/Resources/value.txt")), Data("previous application resource".utf8))
        let unchanged = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(unchanged.first?.baseVersionID, working.baseVersionID)
        let materialized = try await fixture.receiver.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("The linked application remains available") }
        XCTAssertEqual(try Data(contentsOf: file.currentURL.appendingPathComponent("Contents/Resources/value.txt")), Data("previous application resource".utf8))
        let current = try XCTUnwrap(unchanged.first)
        let uncertain = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(uncertain.state, .identityUncertain, "An application without an executable identity cannot be applied")
        do { try await fixture.receiver.applyApplicationUpdate(uncertain); XCTFail("An unknown native identity must retain the existing package") }
        catch ClipboardHistoryApplicationUpdateError.identityUncertain { }
    }
}
