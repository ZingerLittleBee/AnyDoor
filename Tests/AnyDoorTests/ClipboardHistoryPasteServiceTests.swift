import ClipboardHistoryTestSupport
import AppKit
import Clocks
import XCTest

@testable import AnyDoor
@testable import ClipboardHistory

@MainActor
final class ClipboardHistoryPasteServiceTests: XCTestCase {
    func testWritePreservesItemAndRepresentationOrder() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryPasteServiceTests.order")
        )
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                        .data(typeIdentifier: "public.rtf", Data([0x01, 0x02])),
                    ]
                ),
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "public.html", value: "<b>second</b>"),
                        .data(typeIdentifier: "public.png", Data([0x89, 0x50])),
                    ]
                ),
            ]
        )

        try ClipboardHistoryPasteService.write(materialization, to: pasteboard)

        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Array(items[0].types.map(\.rawValue).prefix(2)),
            ["public.utf8-plain-text", "public.rtf"]
        )
        XCTAssertEqual(
            Array(items[1].types.map(\.rawValue).prefix(2)),
            ["public.html", "public.png"]
        )
        XCTAssertEqual(
            items[0].string(forType: .init("public.utf8-plain-text")),
            "first"
        )
        XCTAssertEqual(
            items[1].data(forType: .init("public.png")),
            Data([0x89, 0x50])
        )
    }

    func testInvalidMaterializationDoesNotClearExistingPasteboard() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("ClipboardHistoryPasteServiceTests.atomic")
        )
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        let materialization = ClipboardHistoryMaterialization(
            items: [
                ClipboardHistoryMaterializedItem(
                    representations: [
                        .text(typeIdentifier: "", value: "invalid")
                    ]
                )
            ]
        )

        XCTAssertThrowsError(
            try ClipboardHistoryPasteService.write(
                materialization,
                to: pasteboard
            )
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testCopyEntryWritesItemsAndRepresentationsInOrder() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "public.utf8-plain-text", value: "first"),
                            .data(typeIdentifier: "public.rtf", Data([0x01, 0x02])),
                        ]
                    ),
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "public.html", value: "<b>second</b>"),
                            .data(typeIdentifier: "public.png", Data([0x89, 0x50])),
                        ]
                    ),
                ]
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(
            requests,
            [ClipboardHistoryMaterializationRequest(entryID: id, purpose: .normalPaste)]
        )
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(
            Array(items[0].types.map(\.rawValue).prefix(2)),
            ["public.utf8-plain-text", "public.rtf"]
        )
        XCTAssertEqual(
            Array(items[1].types.map(\.rawValue).prefix(2)),
            ["public.html", "public.png"]
        )
        XCTAssertEqual(
            items[0].string(forType: .init("public.utf8-plain-text")),
            "first"
        )
        XCTAssertEqual(
            items[1].data(forType: .init("public.png")),
            Data([0x89, 0x50])
        )
    }

    /// The wall reads `actionFailure` right after the copy returns to decide
    /// on the restore flow, so the failure has to be both carried and kept.
    func testCopyEntryReportsMaterializationFailureWithoutTouchingPasteboard()
        async
    {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let id = ClipboardHistoryEntryID(UUID())
        let presentation = makePresentation { _ in
            throw ClipboardHistoryModuleError.fileCollectionRequiresRestore(
                id,
                ownedCount: 2,
                unavailableCount: 1
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        let failure = ClipboardHistoryActionFailure.fileCollectionRequiresRestore(
            entryID: id,
            ownedCount: 2,
            unavailableCount: 1
        )
        XCTAssertEqual(outcome, .materializationFailed(failure))
        XCTAssertEqual(presentation.actionFailure, failure)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    func testCopyEntryReportsWriteFailureWithoutTouchingPasteboard() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let presentation = makePresentation { _ in
            ClipboardHistoryMaterialization(
                items: [
                    ClipboardHistoryMaterializedItem(
                        representations: [
                            .text(typeIdentifier: "", value: "invalid")
                        ]
                    )
                ]
            )
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .pasteboardWriteFailed)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    /// Every copy materializes again instead of reusing a cached value.
    func testCopyEntryMaterializesAfreshForEveryCopy() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return textMaterialization("copied")
        }

        let first = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )
        let second = await ClipboardHistoryPasteService.copyEntry(
            id,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(first, .copied)
        XCTAssertEqual(second, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(
            presentation.cachedMaterialization(for: id, purpose: .normalPaste)
        )
    }

    func testCopyEntryForwardsPlainTextPurpose() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let id = ClipboardHistoryEntryID(UUID())
        let recorder = MaterializationRequestRecorder()
        let presentation = makePresentation { request in
            await recorder.record(request)
            return textMaterialization("plain")
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            id,
            purpose: .plainTextPaste,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        let requests = await recorder.requests
        XCTAssertEqual(
            requests,
            [ClipboardHistoryMaterializationRequest(entryID: id, purpose: .plainTextPaste)]
        )
        XCTAssertEqual(pasteboard.string(forType: .string), "plain")
    }

    /// A copy from history is a suppressed self-write, not a new capture, so
    /// the real monitor must not record it.
    func testCopyEntryIsSuppressedFromClipboardMonitor() async throws {
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AnyDoor-CopyEntry-\(UUID().uuidString)",
                isDirectory: true
            )
        removeClipboardHistoryDirectoryAfterTest(storeRoot)
        let module = try trackClipboardHistoryModule(
            ClipboardHistoryModule(
                testingDatabaseURL: storeRoot
                    .appendingPathComponent("history.sqlite"),
                databaseKey: Data(repeating: 0x43, count: 32)
            )
        )
        // copyEntry writes through the process-wide funnel, which AppDelegate
        // points at the live module; point it at this one instead.
        let previousFunnel = ClipboardSelfWrites.current
        ClipboardSelfWrites.configure(module.pasteboardSelfWrites)
        defer { ClipboardSelfWrites.configure(previousFunnel) }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardHistoryCaptureMonitor(
            module: module,
            pasteboard: pasteboard,
            installsSystemObservers: false
        )
        await monitor.setEnabled(true)
        let presentation = makePresentation { _ in
            textMaterialization("copied")
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied")
        await monitor.observeForTesting()
        let page = try await module.page(.init())
        XCTAssertTrue(page.entries.isEmpty)
        try await module.closeStoreForTesting()
    }

    func testMaterializationErrorsKeepExactUnavailableCounts() {
        let id = ClipboardHistoryEntryID(UUID())

        XCTAssertEqual(
            ClipboardHistoryActionFailure(
                ClipboardHistoryModuleError.fileReferencesUnavailable(
                    id,
                    count: 3
                )
            ),
            .fileReferencesUnavailable(entryID: id, count: 3)
        )
        XCTAssertEqual(
            ClipboardHistoryActionFailure(
                ClipboardHistoryModuleError.fileCollectionRequiresRestore(
                    id,
                    ownedCount: 2,
                    unavailableCount: 4
                )
            ),
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 2,
                unavailableCount: 4
            )
        )
    }

    func testUnavailablePayloadSaysSoInsteadOfAGenericCopyFailure() {
        // A migrated entry whose owned copy was already gone can never paste.
        // "复制失败" alone invites the user to keep retrying it.
        let notice = ClipboardHistoryActionFailureNotice(.payloadUnavailable)

        XCTAssertEqual(notice.titleKey, .clipboardToastPayloadUnavailable)
        XCTAssertTrue(notice.details.isEmpty)
        XCTAssertNotEqual(
            notice.titleKey,
            .clipboardToastCopyFailed
        )
    }

    func testActionFailureNoticePresentsOwnedAndUnavailableCountsSeparately() {
        let id = ClipboardHistoryEntryID(UUID())
        let notice = ClipboardHistoryActionFailureNotice(
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 2,
                unavailableCount: 4
            )
        )

        XCTAssertEqual(notice.titleKey, .clipboardToastCopyFailed)
        XCTAssertEqual(
            notice.details,
            [
                .legacyOwned(count: 2),
                .unavailable(count: 4),
            ]
        )
        let message = notice.message
        XCTAssertTrue(
            message.contains(L(.clipboardToastLegacyOwnedCount, 2))
        )
        XCTAssertTrue(
            message.contains(L(.clipboardToastUnavailableCount, 4))
        )
    }

    /// A zero count explains nothing ("0 files to restore"), and either count
    /// can be zero, so the notice lists only what is there.
    func testRestoreNoticeOmitsZeroCounts() {
        let id = ClipboardHistoryEntryID(UUID())
        let unavailableOnly = ClipboardHistoryActionFailureNotice(
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 0,
                unavailableCount: 3
            )
        )
        XCTAssertEqual(unavailableOnly.details, [.unavailable(count: 3)])
        XCTAssertFalse(
            unavailableOnly.message.contains(L(.clipboardToastLegacyOwnedCount, 0))
        )

        let ownedOnly = ClipboardHistoryActionFailureNotice(
            .fileCollectionRequiresRestore(
                entryID: id,
                ownedCount: 2,
                unavailableCount: 0
            )
        )
        XCTAssertEqual(ownedOnly.details, [.legacyOwned(count: 2)])
        XCTAssertFalse(
            ownedOnly.message.contains(L(.clipboardToastUnavailableCount, 0))
        )
    }

    /// ⌥↵ on an entry with no exact text on some item used to report "Copy
    /// failed". It says what is actually the matter, and writes nothing.
    func testPlainTextCopyWithoutExactTextReportsPlainTextUnavailable() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let presentation = makePresentation { request in
            guard request.purpose == .plainTextPaste else {
                return textMaterialization("full")
            }
            throw ClipboardHistoryModuleError.operationUnavailable
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            purpose: .plainTextPaste,
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .plainTextUnavailable)
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
        XCTAssertEqual(
            ClipboardHistoryActionFailurePresenter.failureMessage(for: outcome),
            L(.clipboardToastPlainTextUnavailable)
        )
    }

    /// Only a plain-text paste reads the module's refusal as "no plain text".
    func testNormalCopyKeepsOperationUnavailableAsAMaterializationFailure()
        async
    {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let presentation = makePresentation { _ in
            throw ClipboardHistoryModuleError.operationUnavailable
        }

        let outcome = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )

        XCTAssertEqual(outcome, .materializationFailed(.operationUnavailable))
        XCTAssertEqual(
            ClipboardHistoryActionFailurePresenter.failureMessage(for: outcome),
            L(.clipboardToastCopyFailed)
        )
    }

    /// A copy nobody wants anymore writes nothing, and reports nothing, not
    /// even a failure.
    func testAnUnwantedCopyIsDiscardedSilently() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let changeCount = pasteboard.changeCount
        let copying = makePresentation { _ in textMaterialization("late") }
        let failing = makePresentation { _ in
            throw ClipboardHistoryModuleError.storageFailure
        }

        let copied = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: copying,
            to: pasteboard,
            isWanted: { false }
        )
        let failed = await ClipboardHistoryPasteService.copyEntry(
            ClipboardHistoryEntryID(UUID()),
            from: failing,
            to: pasteboard,
            isWanted: { false }
        )

        XCTAssertEqual(copied, .discarded)
        XCTAssertEqual(failed, .discarded)
        XCTAssertNil(
            ClipboardHistoryActionFailurePresenter.failureMessage(for: copied)
        )
        XCTAssertEqual(pasteboard.changeCount, changeCount)
        XCTAssertEqual(pasteboard.string(forType: .string), "keep")
    }

    /// Return pressed again, or another entry chosen, while a slow entry is
    /// still copying: the newer commit wins. The older one writes nothing
    /// once its entry finally arrives, so the paste lands once and holds
    /// what was chosen last.
    func testANewerCommitSupersedesOneStillCopying() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let slow = ClipboardHistoryEntryID(UUID())
        let gate = AsyncGate()
        addTeardownBlock { await gate.open() }
        let presentation = makePresentation { request in
            guard request.entryID == slow else {
                return textMaterialization("newer")
            }
            await gate.wait()
            return textMaterialization("older")
        }
        let older = CommitProbe()
        let newer = CommitProbe()

        let olderCommit = Task {
            await older.commit(slow, from: presentation, to: pasteboard)
        }
        await waitUntil("the older entry is materializing") {
            await gate.waiterCount == 1
        }
        await newer.commit(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )
        await waitUntil("the newer commit pasted") { newer.pasteCount == 1 }
        XCTAssertEqual(newer.closeCount, 1)

        await gate.open()
        try await bounded(within: 5) { await olderCommit.value }

        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        XCTAssertEqual(older.closeCount, 0)
        XCTAssertEqual(older.toasts, [])
        XCTAssertEqual(older.failures, [])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(older.pasteCount, 0)
        XCTAssertEqual(newer.pasteCount, 1)
    }

    /// Esc or a click elsewhere closed the surface while the entry copied.
    /// The pasteboard holds nothing newer, so the copy still lands and says
    /// so, but ⌘V never follows: it would go to an app nobody chose.
    func testACommitWhoseSurfaceClosedCopiesWithoutPasting() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let gate = AsyncGate()
        addTeardownBlock { await gate.open() }
        let presentation = makePresentation { _ in
            await gate.wait()
            return textMaterialization("chosen")
        }
        let probe = CommitProbe()

        let commit = Task {
            await probe.commit(
                ClipboardHistoryEntryID(UUID()),
                from: presentation,
                to: pasteboard
            )
        }
        await waitUntil("the entry is materializing") {
            await gate.waiterCount == 1
        }
        probe.isOpen = false
        await gate.open()
        try await bounded(within: 5) { await commit.value }

        XCTAssertEqual(pasteboard.string(forType: .string), "chosen")
        XCTAssertEqual(probe.toasts, [.success(L(.toastCopiedToClipboard))])
        XCTAssertEqual(probe.closeCount, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.pasteCount, 0)
    }

    /// The same, after the user copied something else meanwhile: the late
    /// copy must not overwrite it, so it writes nothing and stays quiet.
    func testACommitWhoseSurfaceClosedNeverOverwritesNewerContent()
        async throws
    {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let gate = AsyncGate()
        addTeardownBlock { await gate.open() }
        let presentation = makePresentation { _ in
            await gate.wait()
            return textMaterialization("chosen")
        }
        let probe = CommitProbe()

        let commit = Task {
            await probe.commit(
                ClipboardHistoryEntryID(UUID()),
                from: presentation,
                to: pasteboard
            )
        }
        await waitUntil("the entry is materializing") {
            await gate.waiterCount == 1
        }
        probe.isOpen = false
        pasteboard.clearContents()
        pasteboard.setString("copied elsewhere", forType: .string)
        await gate.open()
        try await bounded(within: 5) { await commit.value }

        XCTAssertEqual(pasteboard.string(forType: .string), "copied elsewhere")
        XCTAssertEqual(probe.toasts, [])
        XCTAssertEqual(probe.failures, [])
        XCTAssertEqual(probe.closeCount, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.pasteCount, 0)
    }

    /// A context-menu Copy takes a commit too, so a Return chosen while it
    /// still copies wins, and the Copy neither writes nor confirms.
    func testACopyWithoutPastingIsSupersededLikeAnyCommit() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let slow = ClipboardHistoryEntryID(UUID())
        let gate = AsyncGate()
        addTeardownBlock { await gate.open() }
        let presentation = makePresentation { request in
            guard request.entryID == slow else {
                return textMaterialization("pasted")
            }
            await gate.wait()
            return textMaterialization("copied")
        }
        let copier = CommitProbe()
        let paster = CommitProbe()

        let copy = Task {
            await ClipboardHistoryPasteService.copyWithoutPasting(
                slow,
                from: presentation,
                surfaceIsOpen: { copier.isOpen },
                presentFailure: { copier.failures.append($0) },
                pasteboard: pasteboard,
                notify: { copier.record($0) }
            )
        }
        await waitUntil("the copied entry is materializing") {
            await gate.waiterCount == 1
        }
        await paster.commit(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard
        )
        await gate.open()
        try await bounded(within: 5) { await copy.value }

        XCTAssertEqual(pasteboard.string(forType: .string), "pasted")
        XCTAssertEqual(copier.toasts, [])
        XCTAssertEqual(copier.failures, [])
        XCTAssertEqual(paster.closeCount, 1)
    }

    /// Copy only never pastes, and never waits on the Accessibility check.
    func testPasteAfterClosingDoesNothingInCopyOnlyMode() async throws {
        let gate = AsyncGate()
        addTeardownBlock { await gate.open() }
        let trust = Task {
            await gate.wait()
            return true
        }
        let probe = CommitProbe()

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: true,
                trust: trust,
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [])
    }

    /// With Accessibility, ⌘V goes out once, `pasteDelay` after the surface
    /// has closed.
    func testPasteAfterClosingPastesOnceAfterTheDelay() async throws {
        let clock = TestClock()
        let probe = CommitProbe()
        let pasting = Task {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                clock: clock
            )
        }

        await waitUntil("the paste waits out its delay") {
            await clock.hasSleeper()
        }
        await clock.advance(
            by: ClipboardHistoryPasteService.pasteDelay - .milliseconds(1)
        )
        XCTAssertEqual(probe.pasteCount, 0)
        await clock.advance(by: .milliseconds(1))
        try await bounded(within: 5) { await pasting.value }

        XCTAssertEqual(probe.pasteCount, 1)
        XCTAssertEqual(probe.toasts, [])
    }

    /// Without Accessibility macOS drops a synthesized ⌘V silently, so the
    /// user is told that the entry was copied instead, and nothing is posted.
    func testPasteAfterClosingWithoutAccessibilitySaysSoInsteadOfPasting()
        async throws
    {
        let probe = CommitProbe()

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { false },
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                clock: TestClock()
            )
        }

        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(
            probe.toasts,
            [.failure(L(.clipboardToastPasteNeedsAccessibility))]
        )
    }

    /// The opening click left the paste target frontmost: it gets ⌘V
    /// without being activated again, so a single-display paste never
    /// flickers.
    func testPasteAfterClosingLeavesAFrontmostTargetAlone() async throws {
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 100)

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(focus.activations, [])
        XCTAssertEqual(probe.pasteCount, 1)
        XCTAssertEqual(probe.toasts, [])
    }

    /// The opening click activated another display's app: the target is
    /// activated, and ⌘V goes out only once it is frontmost.
    func testPasteAfterClosingReactivatesTheTargetBeforePasting() async throws {
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 200)
        focus.checksUntilFrontmost = 3

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: {
                    XCTAssertEqual(focus.frontmost, 100)
                    probe.pasteCount += 1
                },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(focus.activations, [100])
        XCTAssertEqual(probe.pasteCount, 1)
        XCTAssertEqual(probe.toasts, [])
    }

    /// No ⌘V goes out while the target is still on its way to the front,
    /// and `pasteDelay` starts only once it is there.
    func testPasteAfterClosingWaitsForTheTargetBeforeThePasteDelay()
        async throws
    {
        let clock = TestClock()
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 200)
        focus.checksUntilFrontmost = 2
        let pasting = Task {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: clock
            )
        }

        await waitUntil("the paste polls for its target") {
            await clock.hasSleeper()
        }
        XCTAssertEqual(focus.activations, [100])
        await clock.advance(by: ClipboardHistoryPasteService.focusPollInterval)
        await waitUntil("the paste polls again") { focus.checks == 2 }
        XCTAssertNotEqual(focus.frontmost, 100)
        await waitUntil("the paste sleeps again") { await clock.hasSleeper() }
        await clock.advance(by: ClipboardHistoryPasteService.focusPollInterval)
        await waitUntil("the target came forward") { focus.frontmost == 100 }
        await waitUntil("the paste waits out its delay") {
            await clock.hasSleeper()
        }
        await clock.advance(
            by: ClipboardHistoryPasteService.pasteDelay - .milliseconds(1)
        )
        XCTAssertEqual(probe.pasteCount, 0)
        await clock.advance(by: .milliseconds(1))
        try await bounded(within: 5) { await pasting.value }

        XCTAssertEqual(probe.pasteCount, 1)
        XCTAssertEqual(probe.toasts, [])
    }

    /// A target that never comes forward gets no ⌘V: the paste gives up
    /// after `focusTimeout` and says the entry was copied.
    func testPasteAfterClosingGivesUpOnATargetThatNeverComesForward()
        async throws
    {
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 200)

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(focus.activations, [100])
        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [.success(L(.toastCopiedToClipboard))])
        let polls = Int(
            ClipboardHistoryPasteService.focusTimeout
                / ClipboardHistoryPasteService.focusPollInterval
        )
        // One check before activating, then one per poll.
        XCTAssertEqual(focus.checks, 1 + polls)
    }

    /// A target that quit meanwhile cannot be activated, so nothing is
    /// pasted.
    func testPasteAfterClosingDoesNotPasteForAGoneTarget() async throws {
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 200)
        focus.activationSucceeds = false

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [.success(L(.toastCopiedToClipboard))])
    }

    /// The target lost the front again during `pasteDelay`: ⌘V would land
    /// elsewhere, so none is posted.
    func testPasteAfterClosingChecksTheTargetAgainBeforePasting()
        async throws
    {
        let clock = TestClock()
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 100)
        let pasting = Task {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: clock
            )
        }

        await waitUntil("the paste waits out its delay") {
            await clock.hasSleeper()
        }
        focus.frontmost = 200
        await clock.advance(by: ClipboardHistoryPasteService.pasteDelay)
        try await bounded(within: 5) { await pasting.value }

        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [.success(L(.toastCopiedToClipboard))])
    }

    /// A newer commit while the target comes forward ends this one
    /// silently.
    func testASupersededPasteStopsWaitingForItsTarget() async throws {
        let probe = CommitProbe()
        let focus = FocusProbe(frontmost: 200)
        focus.onCheck = { probe.isOpen = false }

        try await bounded(within: 5) {
            await ClipboardHistoryPasteService.pasteAfterClosing(
                copyOnly: false,
                trust: Task { true },
                target: .application(100),
                isCurrent: { probe.isOpen },
                paste: { probe.pasteCount += 1 },
                notify: { probe.record($0) },
                focus: focus.focus,
                clock: ImmediateClock()
            )
        }

        XCTAssertEqual(focus.activations, [100])
        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [])
    }

    /// The panel's opening click activated another app, and the app before
    /// it is unknown: the entry is copied, never pasted, and nothing is
    /// activated.
    func testACommitWithAnUnavailableTargetCopiesWithoutPasting()
        async throws
    {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let presentation = makePresentation { _ in
            textMaterialization("chosen")
        }
        let probe = CommitProbe()
        let surface = ClipboardHistoryCommitSurface(
            isOpen: { probe.isOpen },
            close: { then in
                probe.closeCount += 1
                probe.isOpen = false
                then()
            },
            pasteTarget: { .unavailable }
        )

        await probe.commit(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard,
            surface: surface
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "chosen")
        XCTAssertEqual(probe.closeCount, 1)
        await waitUntil("the paste reports the copy") { !probe.toasts.isEmpty }
        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [.success(L(.toastCopiedToClipboard))])
    }

    /// The surface opened again before ⌘V went out, as when the wall hotkey
    /// lands right after the slide-out. ⌘V would reach the surface, so none
    /// is posted.
    func testACommitNeverPastesIntoAReopenedSurface() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let presentation = makePresentation { _ in
            textMaterialization("chosen")
        }
        let probe = CommitProbe()
        let reopened = ClipboardHistoryCommitSurface(
            isOpen: { true },
            close: { then in
                probe.closeCount += 1
                then()
            },
            isStillClosed: { false }
        )

        await probe.commit(
            ClipboardHistoryEntryID(UUID()),
            from: presentation,
            to: pasteboard,
            surface: reopened
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "chosen")
        XCTAssertEqual(probe.closeCount, 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(probe.pasteCount, 0)
        XCTAssertEqual(probe.toasts, [])
    }

    /// A private pasteboard that already holds "keep", so a failed copy can be
    /// shown to have left it alone. The caller releases it.
    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "ClipboardHistoryPasteServiceTests.\(UUID().uuidString)"
            )
        )
        pasteboard.clearContents()
        pasteboard.setString("keep", forType: .string)
        return pasteboard
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

private func textMaterialization(
    _ value: String
) -> ClipboardHistoryMaterialization {
    ClipboardHistoryMaterialization(
        items: [
            ClipboardHistoryMaterializedItem(
                representations: [
                    .text(typeIdentifier: "public.utf8-plain-text", value: value)
                ]
            )
        ]
    )
}

private actor MaterializationRequestRecorder {
    private(set) var requests: [ClipboardHistoryMaterializationRequest] = []

    func record(_ request: ClipboardHistoryMaterializationRequest) {
        requests.append(request)
    }
}

/// A commit's surface, and the seams it pastes and toasts through, recorded.
/// Its commits run with Accessibility granted, Copy only off, and a clock
/// that never waits, so a paste shows up as soon as the surface closes.
@MainActor
final class CommitProbe {
    enum Toast: Equatable {
        case success(String)
        case failure(String)
        case other(String)
    }

    var isOpen = true
    var closeCount = 0
    var pasteCount = 0
    var toasts: [Toast] = []
    var failures: [ClipboardHistoryCopyOutcome] = []

    /// Closing runs `then` at once, as the menu panel does.
    var surface: ClipboardHistoryCommitSurface {
        ClipboardHistoryCommitSurface(
            isOpen: { self.isOpen },
            close: { then in
                self.closeCount += 1
                self.isOpen = false
                then()
            }
        )
    }

    func record(_ style: ToastStyle) {
        switch style {
        case .success(let message):
            toasts.append(.success(message))
        case .failure(let message):
            toasts.append(.failure(message))
        case .info, .color:
            toasts.append(.other(style.message))
        }
    }

    func commit(
        _ entryID: ClipboardHistoryEntryID,
        plain: Bool = false,
        from presentation: ClipboardHistoryPresentationModel,
        to pasteboard: NSPasteboard,
        surface: ClipboardHistoryCommitSurface? = nil
    ) async {
        await ClipboardHistoryPasteService.commit(
            entryID,
            plain: plain,
            from: presentation,
            surface: surface ?? self.surface,
            presentFailure: { self.failures.append($0) },
            copyOnly: false,
            pasteboard: pasteboard,
            isTrusted: { true },
            paste: { self.pasteCount += 1 },
            notify: { self.record($0) },
            clock: ImmediateClock()
        )
    }
}

/// The app activation a paste goes through, simulated. `frontmost` is the
/// frontmost process; an activation brings its app forward on the
/// `checksUntilFrontmost`th frontmost check after it.
@MainActor
final class FocusProbe {
    var frontmost: pid_t?
    var checksUntilFrontmost = Int.max
    var activationSucceeds = true
    var onCheck: () -> Void = {}
    private(set) var activations: [pid_t] = []
    private(set) var checks = 0
    private var pending: (processID: pid_t, remaining: Int)?

    init(frontmost: pid_t?) {
        self.frontmost = frontmost
    }

    var focus: ClipboardHistoryPasteFocus {
        ClipboardHistoryPasteFocus(
            isFrontmost: { processID in
                self.checks += 1
                self.onCheck()
                if let pending = self.pending {
                    if pending.remaining <= 1 {
                        self.frontmost = pending.processID
                        self.pending = nil
                    } else {
                        self.pending = (pending.processID, pending.remaining - 1)
                    }
                }
                return self.frontmost == processID
            },
            activate: { processID in
                self.activations.append(processID)
                guard self.activationSucceeds else { return false }
                self.pending = (processID, self.checksUntilFrontmost)
                return true
            }
        )
    }
}

/// Suspends callers until the test opens it, so work can be held in flight.
/// Open it in teardown too, so nothing stays suspended after a failure.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiterCount = 0

    func wait() async {
        guard !isOpen else { return }
        waiterCount += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

extension TestClock where Duration == Swift.Duration {
    /// Whether something is sleeping on the clock, so a test can advance it
    /// knowing the sleep it means to end has started.
    func hasSleeper() async -> Bool {
        do {
            try await checkSuspension()
            return false
        } catch {
            return true
        }
    }
}
