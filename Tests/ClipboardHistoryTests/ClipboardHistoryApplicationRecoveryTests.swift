import Foundation
import XCTest

@testable import ClipboardHistory

extension ClipboardHistoryLinkedFileTests {
    @MainActor
    func testConcurrentSyncRetryDoesNotRetireAnActiveApplicationReplacement() async throws {
        let barrier = LinkedReplacementBarrier()
        defer { barrier.release() }
        let fixture = try await makeLinkedFixture(receiverFault: .init { point in
            if point == .linkedFileBeforeReplacement { barrier.pause() }
            return false
        }, prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            _ = try ClipboardApplicationTestFixture.create(at: url,
                bundleIdentifier: "dev.bybee.AnyDoor.tests.active-apply.\(UUID().uuidString)",
                resource: "complete old package", signed: false)
        }, sourceName: "Active Update.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let installed = ClipboardApplicationTestFixture(url: working.url)
        let baseline = try installed.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        try Data("explicit active update".utf8).write(to: fixture.original.appendingPathComponent("Contents/Resources/Resource.txt"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(displayed.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(plan.state, .ready)
        let application = Task { try await fixture.receiver.applyApplicationUpdate(plan) }
        try await eventually { barrier.isWaiting }

        await fixture.receiver.retrySync()

        XCTAssertEqual(try installed.contentsSnapshot(), baseline, "The explicit application is still held before exchange")
        barrier.release()
        try await application.value
        XCTAssertEqual(try installed.contentsSnapshot(), try ClipboardApplicationTestFixture(url: fixture.original).contentsSnapshot())
        let applied = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        XCTAssertEqual(applied.first?.id, working.id)
        XCTAssertEqual(applied.first?.baseVersionID, plan.versionID)
    }

    @MainActor
    func testInterruptedSignedApplicationSwapRecoversWhileOffWithoutApplyingNextVersion() async throws {
        let identifier = "dev.bybee.AnyDoor.tests.application-recovery.\(UUID().uuidString)"
        let fixture = try await makeLinkedFixture(receiverFault: .init(points: [.linkedFileAfterNameExchange]), prepareSource: { url in
            try FileManager.default.removeItem(at: url)
            _ = try ClipboardApplicationTestFixture.create(at: url, bundleIdentifier: identifier, resource: "installed signed version")
        }, sourceName: "Recoverable.app")
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let working = try XCTUnwrap(locations.first)
        let installed = ClipboardApplicationTestFixture(url: working.url)
        let baseline = try installed.contentsSnapshot()
        try await fixture.sender.setSyncEnabled(false)
        try await fixture.receiver.setSyncEnabled(false)
        let candidate = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Candidate.app"),
            bundleIdentifier: identifier, resource: "explicitly accepted signed version")
        try FileManager.default.removeItem(at: fixture.original.appendingPathComponent("Contents"))
        try FileManager.default.copyItem(at: candidate.url.appendingPathComponent("Contents"), to: fixture.original.appendingPathComponent("Contents"))
        try await fixture.sender.setSyncEnabled(true)
        try await fixture.receiver.setSyncEnabled(true)
        let displayed = try await fixture.receiver.linkedFileLocations(for: fixture.entryID)
        let current = try XCTUnwrap(displayed.first)
        let plan = try await fixture.receiver.applicationUpdatePlan(.init(entryID: fixture.entryID,
            locationID: current.id, expectedRevision: current.revision))
        XCTAssertEqual(plan.state, .ready)

        do {
            try await fixture.receiver.applyApplicationUpdate(plan)
            XCTFail("The injected interruption must occur after the complete exchange")
        } catch {}

        try installed.verifySignature()
        XCTAssertEqual(try installed.contentsSnapshot(), try candidate.contentsSnapshot())
        let siblings = try FileManager.default.contentsOfDirectory(at: working.url.deletingLastPathComponent(),
            includingPropertiesForKeys: nil)
        let backup = try XCTUnwrap(siblings.first { $0.lastPathComponent.contains("AnyDoor update") })
        let previous = ClipboardApplicationTestFixture(url: backup)
        try previous.verifySignature()
        XCTAssertEqual(try previous.contentsSnapshot(), baseline, "The interrupted journal still owns a complete old root")
        try await fixture.receiver.closeStoreForTesting()
        try await fixture.sender.setSyncEnabled(false)
        let later = try ClipboardApplicationTestFixture.create(at: fixture.root.appendingPathComponent("Later.app"),
            bundleIdentifier: identifier, resource: "later version without application consent")
        try FileManager.default.removeItem(at: fixture.original.appendingPathComponent("Contents"))
        try FileManager.default.copyItem(at: later.url.appendingPathComponent("Contents"), to: fixture.original.appendingPathComponent("Contents"))
        try await fixture.sender.setSyncEnabled(true)
        let downloadsBefore = await fixture.cloud.downloadedFileVersions()
        let reopened = makeLinkedModule(root: fixture.receiverRoot, services: fixture.services, key: 0x52)

        try await reopened.setSyncEnabled(false)
        let recovered = try await reopened.page(.init())
        let materialized = try await reopened.materialize(.init(entryID: fixture.entryID, purpose: .normalPaste))

        XCTAssertEqual(recovered.entries.first?.linkedFileLocations.first?.baseVersionID, plan.versionID)
        guard case .file(let file) = materialized.items.first?.representations.first else { return XCTFail("Missing recovered complete application") }
        XCTAssertEqual(file.currentURL.resolvingSymlinksInPath(), working.url.resolvingSymlinksInPath())
        try ClipboardApplicationTestFixture(url: file.currentURL).verifySignature()
        XCTAssertEqual(try installed.contentsSnapshot(), try candidate.contentsSnapshot())
        XCTAssertNotEqual(try installed.contentsSnapshot(), try later.contentsSnapshot())
        if FileManager.default.fileExists(atPath: backup.path) {
            try previous.verifySignature()
            XCTAssertEqual(try previous.contentsSnapshot(), baseline)
        }
        let status = await reopened.syncStatus()
        XCTAssertFalse(status.isEnabled)
        let downloadsAfter = await fixture.cloud.downloadedFileVersions()
        XCTAssertEqual(downloadsAfter, downloadsBefore)
    }
}
