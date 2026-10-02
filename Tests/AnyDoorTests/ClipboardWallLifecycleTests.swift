import AppKit
import ClipboardHistory
import XCTest
@testable import AnyDoor

/// The wall's slide order without AppKit: what becomes of a dismissal, a key
/// press and a paste that arrive while the wall slides in or out.
@MainActor
final class ClipboardWallLifecycleTests: XCTestCase {
    /// A paste's ⌘V waits for the slide-out: it must reach the previous app,
    /// not the wall that still holds key focus while it slides away.
    func testCompletionsRunOnlyOnceTheSlideOutEnds() {
        var lifecycle = ClipboardWallLifecycle()
        let log = CompletionLog()
        lifecycle.beginOpening()
        let session = lifecycle.session
        XCTAssertEqual(lifecycle.finishOpening(session: session), .open)
        XCTAssertTrue(lifecycle.acceptsInput)

        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: true) { log.ran.append(1) },
            .start(restoreFocus: true)
        )
        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: false) { log.ran.append(2) },
            .wait
        )
        XCTAssertTrue(log.ran.isEmpty)

        for completion in lifecycle.finishClosing(session: session) {
            completion()
        }
        XCTAssertEqual(log.ran, [1, 2])
        XCTAssertEqual(lifecycle.phase, .closed)
    }

    /// Esc, a click elsewhere or a plugin asked the wall to close while it
    /// slid in. That used to be dropped; now the wall closes once it is open.
    func testADismissalDuringTheSlideInRunsOnceTheWallIsOpen() {
        var lifecycle = ClipboardWallLifecycle()
        let log = CompletionLog()
        lifecycle.beginOpening()
        XCTAssertTrue(lifecycle.acceptsInput, "keys work while the wall slides in")

        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: false) { log.ran.append(1) },
            .wait
        )
        XCTAssertFalse(
            lifecycle.acceptsInput,
            "nothing acts on a wall that is about to close"
        )
        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: true, completion: nil),
            .wait
        )

        XCTAssertEqual(
            lifecycle.finishOpening(session: lifecycle.session),
            .dismiss(restoreFocus: true)
        )
        XCTAssertEqual(lifecycle.phase, .open)
        XCTAssertNil(lifecycle.deferredRestoreFocus)
        // The controller dismisses now, which starts the slide-out.
        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: true, completion: nil),
            .start(restoreFocus: true)
        )
        XCTAssertTrue(log.ran.isEmpty)
        for completion in lifecycle.finishClosing(session: lifecycle.session) {
            completion()
        }
        XCTAssertEqual(log.ran, [1])
    }

    /// ⌘-Tab during the slide-in takes key focus away. The wall used to stay
    /// up over the other app; it now closes as soon as it is open.
    func testLosingKeyFocusDuringTheSlideInClosesTheWallOnceOpen() {
        var lifecycle = ClipboardWallLifecycle()
        lifecycle.beginOpening()
        XCTAssertTrue(
            ClipboardWallDismissalPolicy.shouldDismissAfterResigningKey(
                hasTextWindow: false,
                hasQuickLook: false,
                isOpening: lifecycle.phase == .opening,
                openedOverAnotherApp: true
            )
        )

        XCTAssertEqual(
            lifecycle.requestDismissal(restoreFocus: false, completion: nil),
            .wait
        )
        XCTAssertEqual(
            lifecycle.finishOpening(session: lifecycle.session),
            .dismiss(restoreFocus: false)
        )
    }

    /// Keys pressed while the wall slides out no longer reach it: a quick ⌫
    /// after Return used to delete the selected entry.
    func testKeysAreSwallowedWhileTheWallCloses() {
        var lifecycle = ClipboardWallLifecycle()
        lifecycle.beginOpening()
        let session = lifecycle.session
        _ = lifecycle.finishOpening(session: session)
        XCTAssertTrue(lifecycle.isOpen(forSession: session))

        _ = lifecycle.requestDismissal(restoreFocus: true, completion: nil)

        XCTAssertEqual(lifecycle.phase, .closing)
        XCTAssertTrue(lifecycle.isAnimating)
        XCTAssertFalse(lifecycle.acceptsInput)
        XCTAssertFalse(lifecycle.isOpen(forSession: session))
        _ = lifecycle.finishClosing(session: session)
        XCTAssertFalse(lifecycle.acceptsInput)
    }

    /// A paste after the slide-out checks that the wall stayed closed: the
    /// wall hotkey can reopen it before ⌘V goes out.
    func testAWallThatOpensAgainIsNoLongerClosedForItsEarlierSession() {
        var lifecycle = ClipboardWallLifecycle()
        lifecycle.beginOpening()
        let session = lifecycle.session
        _ = lifecycle.finishOpening(session: session)
        XCTAssertFalse(lifecycle.isClosed(sinceSession: session))

        _ = lifecycle.requestDismissal(restoreFocus: true, completion: nil)
        XCTAssertFalse(lifecycle.isClosed(sinceSession: session))
        _ = lifecycle.finishClosing(session: session)
        XCTAssertTrue(lifecycle.isClosed(sinceSession: session))

        lifecycle.beginOpening()
        XCTAssertFalse(lifecycle.isClosed(sinceSession: session))
    }

    /// A new session starts clean: nothing an earlier one queued or deferred
    /// carries over, and the earlier session's slide-in end is ignored.
    func testBeginningToOpenStartsClean() {
        var lifecycle = ClipboardWallLifecycle()
        let log = CompletionLog()
        lifecycle.beginOpening()
        let first = lifecycle.session
        _ = lifecycle.requestDismissal(restoreFocus: true) { log.ran.append(1) }

        lifecycle.beginOpening()

        XCTAssertNotEqual(lifecycle.session, first)
        XCTAssertNil(lifecycle.deferredRestoreFocus)
        XCTAssertTrue(lifecycle.acceptsInput)
        XCTAssertFalse(lifecycle.isOpen(forSession: first))
        XCTAssertEqual(lifecycle.finishOpening(session: first), .stale)
        XCTAssertEqual(lifecycle.finishOpening(session: lifecycle.session), .open)
        _ = lifecycle.requestDismissal(restoreFocus: false, completion: nil)
        for completion in lifecycle.finishClosing(session: lifecycle.session) {
            completion()
        }
        XCTAssertTrue(log.ran.isEmpty)
    }

    /// With nothing on screen there is no slide to wait for. Settling runs
    /// what was queued at once, so no paste can leak into a later session.
    func testSettlingWithNothingOnScreenRunsWhatWasQueued() {
        var lifecycle = ClipboardWallLifecycle()
        let log = CompletionLog()
        lifecycle.beginOpening()
        let first = lifecycle.session
        _ = lifecycle.requestDismissal(restoreFocus: true) { log.ran.append(1) }

        for completion in lifecycle.settle(adding: { log.ran.append(2) }) {
            completion()
        }

        XCTAssertEqual(log.ran, [1, 2])
        XCTAssertEqual(lifecycle.phase, .closed)
        XCTAssertNil(lifecycle.deferredRestoreFocus)
        XCTAssertEqual(lifecycle.finishOpening(session: first), .stale)
        lifecycle.beginOpening()
        _ = lifecycle.finishOpening(session: lifecycle.session)
        _ = lifecycle.requestDismissal(restoreFocus: false, completion: nil)
        for completion in lifecycle.finishClosing(session: lifecycle.session) {
            completion()
        }
        XCTAssertEqual(log.ran, [1, 2])
    }

    /// A running slide-out settles everything when it ends. Settling earlier
    /// would run a paste while the wall is still on screen.
    func testSettlingDuringTheSlideOutLeavesItToTheSlideOut() {
        var lifecycle = ClipboardWallLifecycle()
        let log = CompletionLog()
        lifecycle.beginOpening()
        _ = lifecycle.finishOpening(session: lifecycle.session)
        _ = lifecycle.requestDismissal(restoreFocus: true) { log.ran.append(1) }

        XCTAssertTrue(lifecycle.settle(adding: { log.ran.append(2) }).isEmpty)
        XCTAssertEqual(lifecycle.phase, .closing)

        for completion in lifecycle.finishClosing(session: lifecycle.session) {
            completion()
        }
        XCTAssertEqual(log.ran, [1, 2])
    }

    /// ⌥↵ on an entry without plain text keeps the wall open behind its
    /// toast. Return on another entry in the same session still copies,
    /// closes the wall, and pastes once the wall is off screen.
    func testACommitAfterAPlainTextUnavailableToastStillPastes() async {
        let wall = SimulatedWall()
        wall.open()
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "ClipboardWallLifecycleTests.\(UUID().uuidString)"
            )
        )
        defer { pasteboard.releaseGlobally() }
        let image = ClipboardHistoryEntryID(UUID())
        let presentation = makePresentation { request in
            if request.entryID == image, request.purpose == .plainTextPaste {
                throw ClipboardHistoryModuleError.operationUnavailable
            }
            return ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(
                                typeIdentifier: "public.utf8-plain-text",
                                value: "text"
                            )
                        ]
                    )
                ]
            )
        }
        let probe = CommitProbe()

        await probe.commit(
            image,
            plain: true,
            from: presentation,
            to: pasteboard,
            surface: wall.surface
        )
        XCTAssertEqual(probe.failures, [.plainTextUnavailable])
        XCTAssertEqual(wall.lifecycle.phase, .open)
        XCTAssertTrue(wall.lifecycle.acceptsInput)

        await probe.commit(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard,
            surface: wall.surface
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "text")
        XCTAssertEqual(wall.lifecycle.phase, .closing)
        XCTAssertEqual(probe.pasteCount, 0, "no ⌘V while the wall is on screen")

        wall.finishSlideOut()
        await waitUntil("the paste after the slide-out") {
            probe.pasteCount == 1
        }
        XCTAssertEqual(probe.failures, [.plainTextUnavailable])
    }

    private func makePresentation(
        materialize: @escaping @Sendable (
            ClipboardHistoryMaterializationRequest
        ) async throws -> ClipboardHistoryMaterialization
    ) -> ClipboardHistoryPresentationModel {
        ClipboardHistoryPresentationModel(
            operations: ClipboardHistoryPresentationOperations(
                status: {
                    ClipboardHistoryStatus(
                        availability: .ready,
                        isMonitoring: true,
                        searchIndex: .ready
                    )
                },
                page: { _, _ in
                    ClipboardHistoryPage(
                        entries: [],
                        nextCursor: nil,
                        cursorDisposition: .initial
                    )
                },
                apply: { _ in .notFound },
                materialize: materialize,
                tagDefinitions: { [] }
            )
        )
    }
}

/// The controller's half of a wall session without AppKit: a commit closes
/// the wall by asking the lifecycle, and the test ends the slide-out.
@MainActor
private final class SimulatedWall {
    var lifecycle = ClipboardWallLifecycle()

    func open() {
        lifecycle.beginOpening()
        _ = lifecycle.finishOpening(session: lifecycle.session)
    }

    /// Built the way the controller builds a commit's surface.
    var surface: ClipboardHistoryCommitSurface {
        let session = lifecycle.session
        return ClipboardHistoryCommitSurface(
            isOpen: { self.lifecycle.isOpen(forSession: session) },
            close: { then in
                guard self.lifecycle.session == session else { return }
                _ = self.lifecycle.requestDismissal(
                    restoreFocus: true,
                    completion: then
                )
            },
            isStillClosed: { self.lifecycle.isClosed(sinceSession: session) }
        )
    }

    func finishSlideOut() {
        for completion in lifecycle.finishClosing(session: lifecycle.session) {
            completion()
        }
    }
}

@MainActor
private final class CompletionLog {
    var ran: [Int] = []
}
