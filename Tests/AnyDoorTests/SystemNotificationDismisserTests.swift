import Clocks
import Foundation
import Testing
@testable import AnyDoor

private let english = SystemNotificationFixture.english
private let chinese = SystemNotificationFixture.chinese
private func action(_ label: String) -> String { SystemNotificationFixture.action(label) }

/// A scripted Notification Center. Each pass reads the current notifications
/// (only a prefix of them when the scripted read is incomplete), lets the
/// dismisser choose, and applies the chosen notification's scripted response,
/// all in one call like the production surface's single queue hop.
///
/// With a clock, passes take time the way production's do: a walk longer than
/// the pass's time limit stops at the limit and reads incompletely, and an
/// action is sent only if time is left in the pass, taking effect only if it
/// completes in that time.
private actor FakeNotificationCenter: SystemNotificationSurface {
    enum Response: Sendable {
        /// The action removes the notification.
        case dismisses
        /// The action is sent, but the notification stays.
        case ignores
        /// The action succeeds, but the same notification comes back under a
        /// new identity.
        case respawns
    }

    struct Item: Sendable {
        var id: UInt
        var actions: [String]
        var response: Response
    }

    /// Whether a pass's walk completes. An incomplete walk finds only the
    /// first `finding` notifications.
    enum Read: Sendable {
        case complete
        case incomplete(finding: Int)
    }

    private var items: [Item]
    private var script: [Read]
    private let laterReads: Read
    private let clock: ImmediateClock<Duration>?
    private let walkTime: Duration
    private let actionTime: Duration
    private var nextID: UInt = 1_000

    private(set) var passes = 0
    private(set) var performedIDs: [UInt] = []
    private(set) var performedActions: [String] = []
    private(set) var timeLimits: [Duration] = []

    /// - Parameters:
    ///   - reads: How the first passes read, in order.
    ///   - laterReads: How every pass after the scripted ones reads.
    ///   - walkTime: Time on `clock` a whole walk takes.
    ///   - actionTime: Time on `clock` performing an action takes.
    init(
        _ items: [Item],
        reads: [Read] = [],
        laterReads: Read = .complete,
        clock: ImmediateClock<Duration>? = nil,
        walkTime: Duration = .zero,
        actionTime: Duration = .zero
    ) {
        self.items = items
        self.script = reads
        self.laterReads = laterReads
        self.clock = clock
        self.walkTime = walkTime
        self.actionTime = actionTime
    }

    var remainingIDs: [UInt] { items.map(\.id) }

    func pass(
        timeLimit: Duration,
        choose: @escaping @Sendable ([SystemNotificationElement]) -> SystemNotificationChoice?
    ) async -> SystemNotificationPass {
        passes += 1
        timeLimits.append(timeLimit)
        guard walkTime <= timeLimit else {
            await spend(timeLimit)
            return SystemNotificationPass(present: [], isComplete: false, actedOn: nil)
        }
        await spend(walkTime)
        let read = script.isEmpty ? laterReads : script.removeFirst()
        let found: [Item]
        let isComplete: Bool
        switch read {
        case .complete:
            found = items
            isComplete = true
        case .incomplete(let finding):
            found = Array(items.prefix(finding))
            isComplete = false
        }
        let present = found.map {
            SystemNotificationElement(id: $0.id, subrole: "AXNotificationCenterBanner", actions: $0.actions)
        }
        let timeLeft = timeLimit - walkTime
        guard let choice = choose(present), present.indices.contains(choice.index), timeLeft > .zero else {
            return SystemNotificationPass(present: present, isComplete: isComplete, actedOn: nil)
        }
        let target = found[choice.index]
        performedIDs.append(target.id)
        performedActions.append(choice.action)
        await spend(min(actionTime, timeLeft))
        if actionTime <= timeLeft {
            apply(target.response, to: target.id)
        }
        return SystemNotificationPass(present: present, isComplete: isComplete, actedOn: target.id)
    }

    private func apply(_ response: Response, to id: UInt) {
        switch response {
        case .dismisses:
            items.removeAll { $0.id == id }
        case .ignores:
            break
        case .respawns:
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].id = nextID
                nextID += 1
            }
        }
    }

    private func spend(_ duration: Duration) async {
        guard let clock, duration > .zero else { return }
        try? await clock.sleep(for: duration)
    }
}

private func banner(_ id: UInt, _ response: FakeNotificationCenter.Response = .dismisses) -> FakeNotificationCenter.Item {
    .init(id: id, actions: ["AXPress", action("Show Details"), action("Close")], response: response)
}

private func stack(_ id: UInt) -> FakeNotificationCenter.Item {
    .init(id: id, actions: ["AXPress", action("Close"), action("Clear All")], response: .dismisses)
}

/// A notification offering only the app's own actions.
private func unrecognized(_ id: UInt) -> FakeNotificationCenter.Item {
    .init(id: id, actions: ["AXPress", action("Reply"), action("Delete")], response: .dismisses)
}

private func dismisser(
    _ center: FakeNotificationCenter,
    labels: SystemNotificationDismissLabels = english,
    clock: ImmediateClock<Duration> = ImmediateClock(),
    settleInterval: Duration = .milliseconds(150),
    maxActions: Int = 60
) -> SystemNotificationDismisser<ImmediateClock<Duration>> {
    SystemNotificationDismisser(
        surface: center,
        labels: labels,
        clock: clock,
        settleInterval: settleInterval,
        maxActions: maxActions
    )
}

struct SystemNotificationDismisserTests {
    // MARK: Outcomes

    @Test func nothingOnScreenIsNothingToDismiss() async {
        let center = FakeNotificationCenter([])
        #expect(await dismisser(center).run() == .nothingToDismiss)
        #expect(await center.passes == 1)
    }

    @Test func dismissesEveryNotificationOnePerPass() async {
        let center = FakeNotificationCenter([banner(1), stack(2), banner(3)])
        #expect(await dismisser(center).run() == .dismissed)
        #expect(await center.performedIDs == [1, 2, 3])
        #expect(await center.performedActions == [action("Close"), action("Clear All"), action("Close")])
        #expect(await center.remainingIDs.isEmpty)
        #expect(await center.passes == 4, "one pass per notification plus the confirming read")
    }

    @Test func dismissesInNotificationCentersLanguageOnly() async {
        let zhBanner = FakeNotificationCenter.Item(
            id: 1, actions: ["AXPress", action("显示详细信息"), action("关闭")], response: .dismisses
        )
        // An app action that happens to be called "Close" is not Notification
        // Center's under a Chinese Notification Center.
        let appAction = FakeNotificationCenter.Item(id: 2, actions: [action("Close")], response: .dismisses)
        let center = FakeNotificationCenter([zhBanner, appAction])
        #expect(await dismisser(center, labels: chinese).run() == .partial)
        #expect(await center.performedIDs == [1])
        #expect(await center.remainingIDs == [2])
    }

    @Test func unrecognizedNotificationsAreNeverTouched() async {
        let center = FakeNotificationCenter([unrecognized(1)])
        #expect(await dismisser(center).run() == .failed)
        #expect(await center.performedIDs.isEmpty)
    }

    @Test func dismissingSomeButNotAllIsPartial() async {
        let center = FakeNotificationCenter([unrecognized(1), banner(2)])
        #expect(await dismisser(center).run() == .partial)
        #expect(await center.performedIDs == [2])
        #expect(await center.remainingIDs == [1])
    }

    // MARK: Stuck elements and stall caps

    @Test func aStuckNotificationIsRetriedThenSkipped() async {
        let center = FakeNotificationCenter([banner(1, .ignores), banner(2)])
        #expect(await dismisser(center).run() == .partial)
        #expect(await center.performedIDs == [1, 1, 1, 2])
    }

    @Test func aNotificationThatNeverGoesAwayFails() async {
        let center = FakeNotificationCenter([banner(1, .ignores)])
        #expect(await dismisser(center).run() == .failed)
        #expect(await center.performedIDs == [1, 1, 1])
    }

    @Test func identityChurnStopsAtTheStallCap() async {
        // Every action "works" but the notification returns under a new
        // identity, which the per-element cap cannot see.
        let center = FakeNotificationCenter([banner(1, .respawns)])
        #expect(await dismisser(center).run() == .failed)
        let performed = await center.performedIDs
        #expect(performed.count == 7, "six stalled actions after the first")
        #expect(Set(performed).count == 7)
    }

    @Test func aReadShowingProgressStillActsPastTheStallCap() async {
        // Two stuck notifications use up the stall allowance before the third
        // is dismissed; the next read shows that progress, so the fourth is
        // still dismissed.
        let center = FakeNotificationCenter([banner(1, .ignores), banner(2, .ignores), banner(3), banner(4)])
        #expect(await dismisser(center).run() == .partial)
        #expect(await center.performedIDs == [1, 1, 1, 2, 2, 2, 3, 4])
        #expect(await center.remainingIDs == [1, 2])
    }

    // MARK: Incomplete reads

    @Test func anIncompleteFirstReadNeverReportsNothingToDismiss() async {
        let center = FakeNotificationCenter([], laterReads: .incomplete(finding: 0))
        #expect(await dismisser(center).run() == .failed)
        #expect(await center.passes == 4, "the first read plus three re-reads")
    }

    @Test func anIncompleteReadMidRunNeverReportsDismissed() async {
        // After the first dismissal the walk keeps failing, hiding banner 2.
        let center = FakeNotificationCenter([banner(1), banner(2)], reads: [.complete], laterReads: .incomplete(finding: 0))
        #expect(await dismisser(center).run() == .failed)
        #expect(await center.performedIDs == [1])
        #expect(await center.remainingIDs == [2])
    }

    @Test func incompleteReadsNeverConcludeEvenWhenNothingIsLeft() async {
        // Each truncated walk still finds one notification to act on, and in
        // the end none is left, but no read ever confirmed that.
        let center = FakeNotificationCenter([banner(1), banner(2)], laterReads: .incomplete(finding: 1))
        #expect(await dismisser(center).run() == .failed)
        #expect(await center.performedIDs == [1, 2])
        #expect(await center.remainingIDs.isEmpty)
    }

    @Test func aTransientIncompleteReadRecovers() async {
        let busy = FakeNotificationCenter([banner(1)], reads: [.incomplete(finding: 0)])
        #expect(await dismisser(busy).run() == .dismissed)
        #expect(await busy.performedIDs == [1])

        let empty = FakeNotificationCenter([], reads: [.incomplete(finding: 0)])
        #expect(await dismisser(empty).run() == .nothingToDismiss)
    }

    // MARK: Budgets

    @Test func theActionBudgetEndsWithAFinalLook() async {
        let center = FakeNotificationCenter((1...5).map { banner($0) })
        #expect(await dismisser(center, maxActions: 2).run() == .partial)
        #expect(await center.performedIDs == [1, 2])
        #expect(await center.passes == 3)
    }

    @Test func theDefaultActionBudgetBoundsLongRuns() async {
        let center = FakeNotificationCenter((1...100).map { banner($0) })
        #expect(await dismisser(center, settleInterval: .zero).run() == .partial)
        #expect(await center.performedIDs.count == 60)
        #expect(await center.remainingIDs.count == 40)
    }

    @Test func slowWalksStillLeaveTimeForACompleteFinalLook() async {
        // One-second walks: seven notifications fit in the time limit together
        // with the read that confirms them gone.
        let clock = ImmediateClock()
        let seven = FakeNotificationCenter(
            (1...7).map { banner($0) }, clock: clock, walkTime: .seconds(1), actionTime: .milliseconds(50)
        )
        let sevenOutcome = await dismisser(seven, clock: clock).run()
        #expect(sevenOutcome == .dismissed)
        let sevenPerformed = await seven.performedIDs
        #expect(sevenPerformed == Array(1...7))
        let lastLimit = await seven.timeLimits.last
        #expect(lastLimit == .milliseconds(1_600), "the final look has time for a whole walk")

        // An eighth would leave too little time to confirm anything, so it is
        // left for the next run instead of ending unconfirmed.
        let eightClock = ImmediateClock()
        let start = eightClock.now
        let eight = FakeNotificationCenter(
            (1...8).map { banner($0) }, clock: eightClock, walkTime: .seconds(1), actionTime: .milliseconds(50)
        )
        let eightOutcome = await dismisser(eight, clock: eightClock).run()
        #expect(eightOutcome == .partial)
        let eightPerformed = await eight.performedIDs
        #expect(eightPerformed == Array(1...7))
        let eightRemaining = await eight.remainingIDs
        #expect(eightRemaining == [8])
        #expect(start.duration(to: eightClock.now) <= .seconds(10))
    }

    @Test func theTimeLimitStopsActingInTimeForAFinalLook() async {
        let clock = ImmediateClock()
        let start = clock.now
        let center = FakeNotificationCenter(
            (1...10).map { banner($0) }, clock: clock, walkTime: .milliseconds(1_400), actionTime: .seconds(1)
        )
        let outcome = await dismisser(center, clock: clock).run()
        #expect(outcome == .partial)
        let performed = await center.performedIDs
        #expect(performed == [1, 2, 3])
        // An acting pass gets what is left after the settle pause and the
        // final look's 1.5 s: the fourth is too short for a walk, and the
        // final look reads completely in the 1.5 s kept for it.
        let limits = await center.timeLimits
        #expect(limits == [
            .milliseconds(8_350), .milliseconds(5_800), .milliseconds(3_250), .milliseconds(700), .milliseconds(1_500),
        ])
        #expect(start.duration(to: clock.now) == .milliseconds(9_900))
    }

    @Test func theTimeLimitBoundsARunThatNeverReadsCompletely() async {
        let clock = ImmediateClock()
        let start = clock.now
        let center = FakeNotificationCenter(
            [banner(1)], laterReads: .incomplete(finding: 0), clock: clock, walkTime: .seconds(4)
        )
        let outcome = await dismisser(center, clock: clock).run()
        #expect(outcome == .failed)
        let limits = await center.timeLimits
        #expect(limits == [.milliseconds(8_350), .milliseconds(4_200), .milliseconds(50), .milliseconds(1_500)])
        #expect(start.duration(to: clock.now) == .seconds(10))
    }

    @Test func aShortPassAfterEarlierIncompleteReadsStillLeavesTheFinalLook() async {
        // Three failed reads use up the re-read allowance before one-second
        // walks dismiss all four. The pass after the last dismissal is too
        // short for a whole walk, but the final look still confirms none is
        // left.
        let clock = ImmediateClock()
        let center = FakeNotificationCenter(
            (1...4).map { banner($0) },
            reads: [.incomplete(finding: 0), .incomplete(finding: 0), .incomplete(finding: 0)],
            clock: clock,
            walkTime: .seconds(1)
        )
        let outcome = await dismisser(center, clock: clock).run()
        #expect(outcome == .dismissed)
        let performed = await center.performedIDs
        #expect(performed == Array(1...4))
        let limits = await center.timeLimits
        #expect(limits == [
            .milliseconds(8_350), .milliseconds(7_200), .milliseconds(6_050), .milliseconds(4_900), .milliseconds(3_750),
            .milliseconds(2_600), .milliseconds(1_450), .milliseconds(300), .milliseconds(1_500),
        ])

        // That final look is still the last pass when it cannot read
        // completely either.
        let unreadableClock = ImmediateClock()
        let unreadable = FakeNotificationCenter(
            (1...4).map { banner($0) },
            reads: [
                .incomplete(finding: 0), .incomplete(finding: 0), .incomplete(finding: 0),
                .complete, .complete, .complete, .complete,
            ],
            laterReads: .incomplete(finding: 0),
            clock: unreadableClock,
            walkTime: .seconds(1)
        )
        let unreadableOutcome = await dismisser(unreadable, clock: unreadableClock).run()
        #expect(unreadableOutcome == .failed)
        #expect(await unreadable.passes == 9)
    }
}
