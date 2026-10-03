import XCTest

@testable import AnyDoor

/// Which app a menu-bar history paste goes to, decided from the activations
/// around the status-item click that opened the panel. Times are event-clock
/// seconds; nothing here touches AppKit.
final class MenuBarPasteTargetTests: XCTestCase {
    private let anyDoor: pid_t = 1
    private let textEdit: pid_t = 100
    private let chatGPT: pid_t = 200
    private let safari: pid_t = 300

    /// Mouse-down at 10.0, mouse-up at 10.1.
    private let click = StatusItemClick(mouseDown: 10.0, mouseUp: 10.1)

    private func history(
        _ activations: (pid_t, TimeInterval)...
    ) -> ApplicationActivationHistory {
        var history = ApplicationActivationHistory()
        for (processID, time) in activations {
            history.record(processID, at: time)
        }
        return history
    }

    private func target(
        _ history: ApplicationActivationHistory,
        after click: StatusItemClick? = nil
    ) -> ClipboardHistoryPasteTarget {
        history.pasteTarget(after: click ?? self.click, selfProcessID: anyDoor)
    }

    // MARK: - Single display: nothing changes

    func testAClickThatActivatesNothingPastesIntoTheFrontmostApp() {
        XCTAssertEqual(target(history((textEdit, 2))), .frontmost)
    }

    func testASwitchJustBeforeTheClickIsNotTheClicks() {
        // ⌘-Tab to ChatGPT, then a click on the status item: ChatGPT is
        // where the user was working.
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 9.9))),
            .frontmost
        )
    }

    func testASwitchLongAfterTheClickIsNotTheClicks() {
        let late = 10.1 + ApplicationActivationHistory.lateActivationGrace + 0.01
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, late))),
            .frontmost
        )
    }

    func testAClickThatEndsOnTheAppAlreadyActiveChangesNothing() {
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 10.02), (textEdit, 10.05))),
            .frontmost
        )
    }

    func testAnyDoorActivatingItselfDuringTheClickChangesNothing() {
        XCTAssertEqual(
            target(history((textEdit, 2), (anyDoor, 10.05))),
            .frontmost
        )
    }

    // MARK: - Another display's menu bar: go back to the prior app

    func testAnActivationDuringTheClickSendsThePasteToThePriorApp() {
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 10.03))),
            .application(textEdit)
        )
    }

    func testANotificationArrivingAfterTheMouseUpStillCounts() {
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 10.4))),
            .application(textEdit)
        )
    }

    func testAnActivationAtTheMouseDownCounts() {
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 10.0))),
            .application(textEdit)
        )
    }

    func testSeveralActivationsDuringTheClickStillGoBackToThePriorApp() {
        XCTAssertEqual(
            target(history((textEdit, 2), (safari, 10.02), (chatGPT, 10.2))),
            .application(textEdit)
        )
    }

    func testTheResultDoesNotDependOnLaterActivations() {
        // AnyDoor reactivating TextEdit, or anything after the grace, is
        // outside the click.
        XCTAssertEqual(
            target(history((textEdit, 2), (chatGPT, 10.05), (textEdit, 30), (safari, 40))),
            .application(textEdit)
        )
    }

    // MARK: - Unknown prior app: copy without pasting

    func testAClickActivationWithNoKnownPriorAppIsUnavailable() {
        XCTAssertEqual(target(history((chatGPT, 10.05))), .unavailable)
    }

    func testAClickActivationAfterAnyDoorItselfIsUnavailable() {
        // AnyDoor's Settings window was in front: never paste into AnyDoor.
        XCTAssertEqual(
            target(history((textEdit, 2), (anyDoor, 5), (chatGPT, 10.05))),
            .unavailable
        )
    }

    func testAPriorAppThatRolledOffTheHistoryIsUnavailable() {
        var recorded = self.history((textEdit, 2))
        // Alternate two apps inside the click window until TextEdit, the
        // only activation before the click, is evicted.
        for index in 0..<ApplicationActivationHistory.capacity {
            recorded.record(index.isMultiple(of: 2) ? chatGPT : safari, at: 10.05)
        }
        XCTAssertEqual(target(recorded), .unavailable)
    }

    // MARK: - History bookkeeping

    func testRepeatedActivationsOfTheSameAppAreRecordedOnce() {
        let recorded = history((textEdit, 1), (textEdit, 2), (chatGPT, 3), (chatGPT, 4))
        XCTAssertEqual(
            recorded.activations,
            [
                .init(processID: textEdit, time: 1),
                .init(processID: chatGPT, time: 3),
            ]
        )
    }

    func testTheHistoryKeepsOnlyTheNewestActivations() {
        var history = ApplicationActivationHistory()
        let count = ApplicationActivationHistory.capacity + 5
        for index in 0..<count {
            history.record(pid_t(1_000 + index), at: TimeInterval(index))
        }
        XCTAssertEqual(history.activations.count, ApplicationActivationHistory.capacity)
        XCTAssertEqual(history.activations.first?.processID, pid_t(1_005))
        XCTAssertEqual(history.activations.last?.processID, pid_t(1_000 + count - 1))
    }

    // MARK: - Click timing

    func testAClickBeginsAtItsMouseDown() {
        let click = StatusItemClick(mouseDown: 4, mouseUp: 7)
        XCTAssertEqual(click.began, 4)
        XCTAssertEqual(click.ended, 7)
    }

    func testAClickWithoutASeenMouseDownBeginsShortlyBeforeItsMouseUp() {
        let missing = StatusItemClick(mouseDown: nil, mouseUp: 7)
        XCTAssertEqual(missing.began, 7 - StatusItemClick.fallbackLead)
        // A mouse-down after the mouse-up belongs to some other click.
        let later = StatusItemClick(mouseDown: 8, mouseUp: 7)
        XCTAssertEqual(later.began, 7 - StatusItemClick.fallbackLead)
    }

    func testAStaleMouseDownDoesNotWidenTheClick() {
        let stale = StatusItemClick(
            mouseDown: 1,
            mouseUp: 1 + StatusItemClick.maximumHold + 0.1
        )
        XCTAssertEqual(stale.began, stale.ended - StatusItemClick.fallbackLead)
        // An app switch between the stale mouse-down and this click is not
        // the click's.
        var history = ApplicationActivationHistory()
        history.record(textEdit, at: 0)
        history.record(chatGPT, at: 3)
        XCTAssertEqual(target(history, after: stale), .frontmost)
    }
}
