import Clocks
import Testing
@testable import AnyDoor

/// A scripted Notification Center panel. A toggle flips it after
/// `toggleDelay` on the clock, the way the live panel animates in, unless
/// toggles are ignored (the Globe+N shortcut is turned off).
private actor FakePanel: NotificationCenterPanel {
    private var open: Bool
    private let readable: Bool
    private let respondsToToggle: Bool
    private let toggleDelay: Duration
    private let clock: ImmediateClock<Duration>
    private var flipsAt: ImmediateClock<Duration>.Instant?

    private(set) var toggles = 0

    init(
        open: Bool = false,
        readable: Bool = true,
        respondsToToggle: Bool = true,
        toggleDelay: Duration = .milliseconds(200),
        clock: ImmediateClock<Duration>
    ) {
        self.open = open
        self.readable = readable
        self.respondsToToggle = respondsToToggle
        self.toggleDelay = toggleDelay
        self.clock = clock
    }

    var isOpenNow: Bool {
        settle()
        return open
    }

    /// Closes the panel the way the user dismissing it would.
    func dismissByUser() {
        settle()
        open = false
    }

    func isOpen() async -> Bool? {
        guard readable else { return nil }
        return isOpenNow
    }

    func toggle() async {
        toggles += 1
        guard respondsToToggle else { return }
        settle()
        flipsAt = clock.now.advanced(by: toggleDelay)
    }

    private func settle() {
        guard let flipsAt, clock.now >= flipsAt else { return }
        open.toggle()
        self.flipsAt = nil
    }
}

private func presenter(
    _ panel: FakePanel,
    clock: ImmediateClock<Duration>
) -> NotificationCenterPanelPresenter<ImmediateClock<Duration>> {
    NotificationCenterPanelPresenter(panel: panel, clock: clock)
}

struct NotificationCenterPanelPresenterTests {
    @Test func opensAClosedPanelAndClosesItAfterwards() async {
        let clock = ImmediateClock()
        let panel = FakePanel(clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .opened)
        #expect(await panel.isOpenNow)

        await presenter.close(after: opening)
        try? await clock.sleep(for: .seconds(1))
        #expect(await !panel.isOpenNow)
        #expect(await panel.toggles == 2)
    }

    @Test func leavesAPanelTheUserOpenedAlone() async {
        let clock = ImmediateClock()
        let panel = FakePanel(open: true, clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .alreadyOpen)
        await presenter.close(after: opening)
        #expect(await panel.isOpenNow)
        #expect(await panel.toggles == 0)
    }

    @Test func givesUpWhenThePanelNeverOpens() async {
        let clock = ImmediateClock()
        let panel = FakePanel(respondsToToggle: false, clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .timedOut)
        #expect(!opening.isOpen)
        await presenter.close(after: opening)
        #expect(await panel.toggles == 1, "a panel that is not open is not toggled again")
    }

    @Test func closesAPanelThatOpenedAfterTheWait() async {
        let clock = ImmediateClock()
        let panel = FakePanel(toggleDelay: .seconds(2), clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .timedOut)
        try? await clock.sleep(for: .seconds(2))
        #expect(await panel.isOpenNow)
        await presenter.close(after: opening)
        try? await clock.sleep(for: .seconds(2))
        #expect(await !panel.isOpenNow)
        #expect(await panel.toggles == 2)
    }

    @Test func doesNotReopenAPanelThatClosedDuringTheRun() async {
        let clock = ImmediateClock()
        let panel = FakePanel(clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .opened)
        await panel.dismissByUser()
        await presenter.close(after: opening)
        #expect(await panel.toggles == 1)
        #expect(await !panel.isOpenNow)
    }

    @Test func leavesAnUnreadablePanelAlone() async {
        let clock = ImmediateClock()
        let panel = FakePanel(readable: false, clock: clock)
        let presenter = presenter(panel, clock: clock)

        let opening = await presenter.open()
        #expect(opening == .unreadable)
        await presenter.close(after: opening)
        #expect(await panel.toggles == 0)
    }
}
