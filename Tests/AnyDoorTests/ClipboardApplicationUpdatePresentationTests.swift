import AppKit
import Foundation
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardApplicationUpdatePresentationTests: XCTestCase {
    func testApplyingUpdatePreservesLoadedHistoryDepthAndSelection() async throws {
        let fixture = try await makeApplicationFixture()
        for index in 0..<105 {
            _ = try await fixture.receiver.capture(.init(source: .unknown, content: .text("history after application \(index)")))
        }
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.reload()
        await model.loadNextPage()
        XCTAssertEqual(model.entries.count, 106)
        model.select(fixture.selection.entryID)
        await model.beginApplicationUpdate(fixture.selection)

        await model.applyApplicationUpdate()

        XCTAssertEqual(model.applicationUpdateNotice, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), fixture.update)
        XCTAssertEqual(model.entries.count, 106)
        XCTAssertEqual(model.selectedID, fixture.selection.entryID)
    }

    func testDownloadedApplicationNeedsAnExplicitApplyAction() async throws {
        let fixture = try await makeApplicationFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)

        XCTAssertEqual(model.applicationUpdatePlan?.state, .ready)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
        await model.applyApplicationUpdate()

        XCTAssertEqual(model.applicationUpdateNotice, .applied)
        XCTAssertNil(model.applicationUpdatePlan)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), fixture.update)
    }

    func testSavedChangesInvalidateTheDisplayedUpdateAndRefreshItsState() async throws {
        let fixture = try await makeApplicationFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)
        let displayed = try XCTUnwrap(model.applicationUpdatePlan)
        let saved = Data("saved while reviewing update".utf8)
        try saved.write(to: fixture.workingResource)

        await model.applyApplicationUpdate()

        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), saved)
        XCTAssertNotEqual(model.applicationUpdatePlan?.id, displayed.id)
        XCTAssertEqual(model.applicationUpdatePlan?.state, .localChanges)
        XCTAssertNotEqual(model.applicationUpdateNotice, .applied)
    }

    func testLargeUpdateDownloadsThenRefreshesWithoutApplyingTheOldPlan() async throws {
        let fixture = try await makeApplicationFixture(update: Data(repeating: 0x71, count: 5_000_001))
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        let before = await fixture.cloud.downloadCount()
        await model.beginApplicationUpdate(fixture.selection)
        let displayed = try XCTUnwrap(model.applicationUpdatePlan)
        XCTAssertEqual(displayed.state, .requiresDownload)
        await model.applyApplicationUpdate()
        let unopened = await fixture.cloud.downloadCount()
        XCTAssertEqual(unopened, before)

        await model.downloadApplicationUpdate()

        let refreshed = try XCTUnwrap(model.applicationUpdatePlan)
        XCTAssertNotEqual(refreshed.id, displayed.id)
        XCTAssertEqual(refreshed.versionID, displayed.versionID)
        XCTAssertEqual(refreshed.state, .ready)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
        XCTAssertNil(model.applicationUpdateNotice)
        await model.applyApplicationUpdate()
        XCTAssertEqual(model.applicationUpdateNotice, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), fixture.update)
    }

    func testClosingDuringDownloadDoesNotReopenOrApplyTheUpdate() async throws {
        let fixture = try await makeApplicationFixture(update: Data(repeating: 0x72, count: 5_000_001))
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)
        await fixture.cloud.holdNextDownload()
        let download = Task { await model.downloadApplicationUpdate() }
        for _ in 0..<1_000 {
            if await fixture.cloud.downloadIsHeld() { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let held = await fixture.cloud.downloadIsHeld()
        XCTAssertTrue(held)
        model.dismissApplicationUpdate()
        await fixture.cloud.releaseDownload()
        await download.value

        XCTAssertNil(model.applicationUpdateSelection)
        XCTAssertNil(model.applicationUpdatePlan)
        XCTAssertNil(model.applicationUpdateNotice)
        XCTAssertFalse(model.isPerformingApplicationUpdateAction)
        XCTAssertFalse(model.hasFileActionSheet)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
    }

    func testFailedDownloadCanRetryWithoutApplyingTheApplication() async throws {
        let fixture = try await makeApplicationFixture(update: Data(repeating: 0x73, count: 5_000_001))
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)
        await fixture.cloud.failDownloads(true)
        await model.downloadApplicationUpdate()
        XCTAssertEqual(model.applicationUpdateNotice, .downloadPending)
        XCTAssertEqual(model.applicationUpdatePlan?.state, .requiresDownload)
        await fixture.cloud.failDownloads(false)

        await model.downloadApplicationUpdate()

        XCTAssertEqual(model.applicationUpdatePlan?.state, .ready)
        XCTAssertNil(model.applicationUpdateNotice)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
    }

    func testChangedLocationRevisionRefreshesWithoutApplyingAnOldToken() async throws {
        let fixture = try await makeApplicationFixture()
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)
        let displayed = try XCTUnwrap(model.applicationUpdatePlan)
        try await fixture.receiver.setFileLocationPaused(fixture.selection, paused: true)

        await model.applyApplicationUpdate()

        XCTAssertEqual(model.applicationUpdateNotice, .changed)
        XCTAssertNotEqual(model.applicationUpdatePlan?.id, displayed.id)
        XCTAssertEqual(model.applicationUpdatePlan?.state, .unavailable)
        XCTAssertNotEqual(model.applicationUpdatePlan?.locationRevision, displayed.locationRevision)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
    }

    func testNestedApplicationUsesTheParentLocationUpdatePlan() async throws {
        let fixture = try await makeApplicationFixture(nested: true)
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)
        await model.beginApplicationUpdate(fixture.selection)
        XCTAssertEqual(model.applicationUpdatePlan?.displayName, "Collection")
        XCTAssertEqual(model.applicationUpdatePlan?.state, .ready)

        await model.applyApplicationUpdate()

        XCTAssertEqual(model.applicationUpdateNotice, .applied)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), fixture.update)
    }

    func testUnprovenReplacementExplainsReassociationAndCannotApply() async throws {
        let fixture = try await makeApplicationFixture()
        let locations = try await fixture.receiver.linkedFileLocations(for: fixture.selection.entryID)
        let location = try XCTUnwrap(locations.first)
        let moved = location.url.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: location.url, to: moved)
        try FileManager.default.copyItem(at: moved, to: location.url)
        let model = ClipboardHistoryPresentationModel(module: fixture.receiver)

        await model.beginApplicationUpdate(fixture.selection)
        let plan = try XCTUnwrap(model.applicationUpdatePlan)
        XCTAssertEqual(plan.state, .identityUncertain)
        XCTAssertEqual(plan.state.applicationUpdateMessageKey, .clipboardApplicationUpdateIdentityUncertain)
        await model.applyApplicationUpdate()

        XCTAssertNil(model.applicationUpdateNotice)
        XCTAssertEqual(try Data(contentsOf: fixture.workingResource), Data("previous resource".utf8))
    }

    private func makeApplicationFixture(update: Data = Data("updated resource".utf8), nested: Bool = false) async throws -> (
        sender: ClipboardHistoryModule, receiver: ClipboardHistoryModule,
        selection: ClipboardHistoryFileLocationSelection, workingResource: URL,
        update: Data, cloud: FileConflictUICloud
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("application-update-ui-\(UUID())")
        removeClipboardHistoryDirectoryAfterTest(root)
        let original = root.appendingPathComponent(nested ? "Collection" : "Fixture.app")
        let bundle = nested ? original.appendingPathComponent("Nested.app") : original
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        try Data("synthetic executable identity".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let plist = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "Fixture", "CFBundleIdentifier": "dev.bybee.AnyDoor.tests.update-ui.\(UUID())"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let relativeResource = (nested ? "Nested.app/" : "") + "Contents/Resources/value.txt"
        let sourceResource = original.appendingPathComponent(relativeResource)
        try Data("previous resource".utf8).write(to: sourceResource)
        let cloud = FileConflictUICloud()
        let services = ClipboardSyncServices(transport: cloud, keys: FileConflictUIKeys(), pollingInterval: nil)
        let sender = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Sender"),
            keyStore: FileConflictUILocalKey(byte: 0x61), syncServices: services))
        let receiver = trackClipboardHistoryModule(ClipboardHistoryModule(testingStoreRoot: root.appendingPathComponent("Receiver"),
            keyStore: FileConflictUILocalKey(byte: 0x62), syncServices: services))
        let pasteboard = NSPasteboard(name: .init("dev.bybee.AnyDoor.application-update-ui.\(UUID())"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(original.absoluteString, forType: .fileURL)
        guard case .captured(let capture) = try await sender.capture(.init(pasteboard: pasteboard), source: .unknown) else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        let tag = try await sender.createTagDefinition(named: "Applications", assigningTo: capture.entryID)
        try await sender.setSyncTagSelected(tag.definition.id, selected: true)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        try await sender.setSyncEnabled(false)
        try await receiver.setSyncEnabled(false)
        try update.write(to: sourceResource)
        try await sender.setSyncEnabled(true)
        try await receiver.setSyncEnabled(true)
        let locations = try await receiver.linkedFileLocations(for: capture.entryID)
        let location = try XCTUnwrap(locations.first)
        XCTAssertNotNil(location.applicationUpdateVersionID)
        return (sender, receiver, .init(entryID: capture.entryID, locationID: location.id, expectedRevision: location.revision),
            location.url.appendingPathComponent(relativeResource), update, cloud)
    }
}
