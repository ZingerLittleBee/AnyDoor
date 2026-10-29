import ClipboardHistory
import Foundation
import XCTest

@testable import AnyDoor

@MainActor
final class ClipboardHistoryLinkedFilePresentationTests: XCTestCase {
    func testExternalMoveRefreshDoesNotReuseTheOldMaterializedLocation() async {
        for refreshLoadedPrefix in [true, false] {
            let client = LinkedLocationPresentationClient()
            let model = ClipboardHistoryPresentationModel(operations: client.operations)
            await model.reload()
            let entryID = model.entries[0].id
            _ = await model.materialization(for: entryID, purpose: .hostAction)
            await client.moveWhilePickerIsOpen()

            if refreshLoadedPrefix { await model.refreshForStoreChange() }
            else { await model.reload() }
            let content = await model.materialization(for: entryID, purpose: .hostAction)

            XCTAssertEqual(model.entries[0].linkedFileLocations[0].revision, 5)
            XCTAssertEqual(content?.fileURLs, [URL(fileURLWithPath: "/fixture/moved.txt")])
        }
    }

    func testReassociationShowsChosenLocationAndMaterializesItsCurrentBytes() async {
        let client = LinkedLocationPresentationClient()
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.reload()
        let original = model.entries[0]
        let location = original.linkedFileLocations[0]
        _ = await model.materialization(for: original.id, purpose: .hostAction)
        let chosen = URL(fileURLWithPath: "/fixture/chosen.txt")

        let accepted = await model.reassociateFileLocation(.init(selection: .init(
            entryID: original.id, locationID: location.id, expectedRevision: location.revision), url: chosen))

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].id, location.id)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].objectID, location.objectID)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].url, chosen)
        XCTAssertNil(model.actionFailure)
        XCTAssertNil(model.cachedMaterialization(for: original.id, purpose: .hostAction))
        let content = await model.materialization(for: original.id, purpose: .hostAction)
        XCTAssertEqual(content?.fileURLs, [chosen])
    }

    func testPauseAndResumeRefreshTheDisplayedLocation() async {
        let client = LinkedLocationPresentationClient()
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.reload()
        let original = model.entries[0]
        let location = original.linkedFileLocations[0]
        _ = await model.materialization(for: original.id, purpose: .hostAction)

        let paused = await model.setFileLocationPaused(.init(entryID: original.id,
            locationID: location.id, expectedRevision: location.revision), paused: true)

        XCTAssertTrue(paused)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].state, .paused)
        XCTAssertNil(model.cachedMaterialization(for: original.id, purpose: .hostAction))
        let current = model.entries[0].linkedFileLocations[0]
        let resumed = await model.setFileLocationPaused(.init(entryID: original.id,
            locationID: current.id, expectedRevision: current.revision), paused: false)
        XCTAssertTrue(resumed)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].state, .current)
        XCTAssertNil(model.actionFailure)
    }

    func testTrackingActionsDoNotOfferResumeForAnUnprovenIdentity() {
        XCTAssertEqual(linkedLocation(state: .identityUncertain).trackingActions, [.reassociate])
        XCTAssertEqual(linkedLocation(state: .detached).trackingActions, [.reassociate])
        XCTAssertEqual(linkedLocation(state: .unavailable).trackingActions, [.retry, .reassociate])
        XCTAssertEqual(linkedLocation(state: .paused).trackingActions, [.resume])
        for state: ClipboardHistoryLinkedFileLocationState in [.current, .localChanges, .pendingUpload, .conflict] {
            XCTAssertEqual(linkedLocation(state: state).trackingActions, [.pause])
        }
    }

    func testRetryRefreshesUnavailableLocationAndRejectsAnOlderPauseSelection() async {
        let client = LinkedLocationPresentationClient(state: .unavailable)
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.reload()
        let displayed = model.entries[0]
        let location = displayed.linkedFileLocations[0]
        let selection = ClipboardHistoryFileLocationSelection(entryID: displayed.id,
            locationID: location.id, expectedRevision: location.revision)

        let retried = await model.setFileLocationPaused(selection, paused: false)
        XCTAssertTrue(retried)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].state, .current)
        _ = await model.materialization(for: displayed.id, purpose: .hostAction)

        let acceptedStalePause = await model.setFileLocationPaused(selection, paused: true)
        XCTAssertFalse(acceptedStalePause)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].state, .current)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].revision, 5)
        XCTAssertEqual(model.actionFailure, .operationUnavailable)
        XCTAssertNil(model.cachedMaterialization(for: displayed.id, purpose: .hostAction))
    }

    func testPausedAndUncertainLocationsDoNotLookLikeAvailableTracking() {
        let available = linkedEntry(linkedLocation()).syncFileStatusText
        for state: ClipboardHistoryLinkedFileLocationState in [.paused, .detached, .identityUncertain] {
            XCTAssertNotEqual(linkedEntry(linkedLocation(state: state)).syncFileStatusText, available)
        }
    }

    func testStaleReassociationRefreshesLocationAndKeepsFailureFeedback() async {
        let client = LinkedLocationPresentationClient()
        let model = ClipboardHistoryPresentationModel(operations: client.operations)
        await model.reload()
        let displayed = model.entries[0]
        let location = displayed.linkedFileLocations[0]
        _ = await model.materialization(for: displayed.id, purpose: .hostAction)
        await client.moveWhilePickerIsOpen()

        let accepted = await model.reassociateFileLocation(.init(selection: .init(
            entryID: displayed.id, locationID: location.id, expectedRevision: location.revision),
            url: URL(fileURLWithPath: "/fixture/chosen.txt")))

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].url.path, "/fixture/moved.txt")
        XCTAssertEqual(model.entries[0].linkedFileLocations[0].revision, 5)
        XCTAssertEqual(model.actionFailure, .operationUnavailable)
        XCTAssertNil(model.cachedMaterialization(for: displayed.id, purpose: .hostAction))
    }

    func testLocationRevisionRefreshesFilePresentationWithoutANewVersion() {
        let location = linkedLocation(revision: 4)
        let moved = ClipboardHistoryLinkedFileLocation(
            id: location.id, objectID: location.objectID, baseVersionID: location.baseVersionID,
            url: URL(fileURLWithPath: "/fixture/moved.txt"), kind: location.kind,
            state: location.state, revision: 5)

        XCTAssertNotEqual(linkedEntry(location).filePresentationIdentity,
            linkedEntry(moved).filePresentationIdentity)
    }
}

private actor LinkedLocationPresentationClient {
    private var location: ClipboardHistoryLinkedFileLocation

    init(state: ClipboardHistoryLinkedFileLocationState = .current) {
        location = linkedLocation(state: state)
    }

    nonisolated var operations: ClipboardHistoryPresentationOperations {
        .init(status: { .init(availability: .ready, isMonitoring: false, searchIndex: .ready) },
            page: { _, _ in await self.page() }, apply: { _ in .notFound },
            materialize: { _ in await self.materialization() }, tagDefinitions: { [] },
            reassociateFileLocation: { try await self.reassociate($0) },
            setFileLocationPaused: { try await self.setPaused($0, paused: $1) })
    }

    func page() -> ClipboardHistoryPage {
        .init(entries: [linkedEntry(location)], nextCursor: nil, cursorDisposition: .initial)
    }

    func materialization() -> ClipboardHistoryMaterialization {
        .init(items: [.init(representations: [.file(.init(capturedPath: location.url.path,
            displayName: location.url.lastPathComponent, currentURL: location.url))])])
    }

    func moveWhilePickerIsOpen() {
        location = .init(id: location.id, objectID: location.objectID, baseVersionID: location.baseVersionID,
            url: URL(fileURLWithPath: "/fixture/moved.txt"), kind: location.kind,
            state: location.state, revision: location.revision + 1)
    }

    func reassociate(_ request: ClipboardHistoryFileLocationReassociation) throws -> ClipboardHistoryLinkedFileLocation {
        guard request.selection.entryID == linkedEntry(location).id,
            request.selection.locationID == location.id,
            request.selection.expectedRevision == location.revision else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        location = .init(id: location.id, objectID: location.objectID, baseVersionID: location.baseVersionID,
            url: request.url, kind: location.kind, state: .localChanges, revision: location.revision + 1)
        return location
    }

    func setPaused(_ selection: ClipboardHistoryFileLocationSelection, paused: Bool) throws {
        guard selection.entryID == linkedEntry(location).id, selection.locationID == location.id,
            selection.expectedRevision == location.revision else {
            throw ClipboardHistoryModuleError.operationUnavailable
        }
        location = .init(id: location.id, objectID: location.objectID, baseVersionID: location.baseVersionID,
            url: location.url, kind: location.kind, state: paused ? .paused : .current,
            revision: location.revision + 1)
    }
}

private func linkedLocation(
    state: ClipboardHistoryLinkedFileLocationState = .current,
    revision: UInt64 = 4
) -> ClipboardHistoryLinkedFileLocation {
    .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        objectID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        baseVersionID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        url: URL(fileURLWithPath: "/fixture/original.txt"), kind: .original,
        state: state, revision: revision)
}

private func linkedEntry(_ location: ClipboardHistoryLinkedFileLocation) -> ClipboardHistoryEntry {
    .init(id: .init(UUID(uuidString: "00000000-0000-0000-0000-000000000004")!),
        capturedAt: Date(timeIntervalSince1970: 0), previewText: "original.txt", facets: [.file],
        isFavorite: false, source: .unknown,
        syncFiles: [.init(id: location.objectID, versionID: location.baseVersionID,
            displayName: "original.txt", originalByteCount: 1, state: .complete)],
        linkedFileLocations: [location])
}
