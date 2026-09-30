import Foundation

/// What one pass saw and did.
struct SystemNotificationPass: Sendable, Equatable {
    /// Every notification the walk found, in document order.
    var present: [SystemNotificationElement]
    /// False when the walk may have missed notifications (a failed read or an
    /// exhausted budget).
    var isComplete: Bool
    /// The notification an action was sent to; nil when nothing was chosen or
    /// the pass ran out of time before sending it. Whether the action worked
    /// is left to the next read.
    var actedOn: UInt?
}

/// One walk-choose-perform pass over Notification Center. Production does all
/// three with AX calls on one serial queue so AXUIElement references never
/// leave it; the chooser runs inside that same hop (hence escaping: it is
/// handed to the queue).
protocol SystemNotificationSurface: Sendable {
    /// Must return within `timeLimit`.
    func pass(
        timeLimit: Duration,
        choose: @escaping @Sendable ([SystemNotificationElement]) -> SystemNotificationChoice?
    ) async -> SystemNotificationPass
}

enum SystemNotificationDismissOutcome: Sendable, Equatable {
    case nothingToDismiss
    case dismissed
    /// Some notifications were dismissed, others remain.
    case partial
    /// Notifications remain and none could be dismissed, or Notification
    /// Center could not be read completely.
    case failed
}

/// Dismisses notifications one per pass until none is left, nothing
/// recognizable remains, or a budget runs out.
///
/// Conclusions come only from complete reads: a walk that failed or was cut
/// short can act on what it found but never reports "dismissed" or "nothing
/// to dismiss", and a run that ends without a complete final read reports
/// `.failed`. To keep that final read possible, a pass that may act is itself
/// limited to the time left after its settle pause and the final look's
/// reserve, however slow the walks are. Outcomes compare notification counts,
/// not identities, because an element whose identity changes between passes
/// would otherwise look like a dismissal.
///
/// Generic over its clock so tests can drive time without sleeping.
struct SystemNotificationDismisser<C: Clock<Duration>>: Sendable {
    let surface: any SystemNotificationSurface
    let labels: SystemNotificationDismissLabels
    let clock: C
    /// Pause after each action for Notification Center to animate it away.
    let settleInterval: Duration
    /// Actions one run may perform.
    let maxActions: Int

    /// Hard limit for the whole run.
    private let timeLimit: Duration = .seconds(10)
    /// Time kept for the confirming read after the last action: one whole
    /// walk, which the live surface caps at 1.5 s.
    private let finalLookReserve: Duration = .milliseconds(1_500)
    private let maxAttemptsPerElement = 3
    /// Consecutive actions without the notification count dropping below its
    /// lowest value so far, after which only a read showing progress may act.
    /// Catches elements whose identity changes every pass, which the
    /// per-element cap cannot see.
    private let maxStalledPasses = 6
    /// Incomplete passes without an action tolerated before giving up. When
    /// a pass that had less than a whole walk's time runs out the allowance,
    /// the final look still follows, since such a pass may read incompletely
    /// on its own.
    private let maxIncompleteRereads = 3

    init(
        surface: any SystemNotificationSurface,
        labels: SystemNotificationDismissLabels,
        clock: C,
        settleInterval: Duration = .milliseconds(150),
        maxActions: Int = 60
    ) {
        self.surface = surface
        self.labels = labels
        self.clock = clock
        self.settleInterval = settleInterval
        self.maxActions = maxActions
    }

    func run() async -> SystemNotificationDismissOutcome {
        let deadline = clock.now.advanced(by: timeLimit)
        var attempts: [UInt: Int] = [:]
        var skipping: Set<UInt> = []
        var actions = 0
        var mostSeen = 0
        var fewestSeen = Int.max
        var stalledPasses = 0
        var incompleteRereads = 0
        var onlyFinalLookLeft = false

        while true {
            let remaining = clock.now.duration(to: deadline)
            // Out of time without a complete read to conclude from.
            guard remaining > .zero else { return .failed }
            // A pass that may act must end, action included, early enough to
            // leave its settle pause and a whole final look; otherwise it is
            // that final look and gets all the time left.
            let actingTime = remaining - settleInterval - finalLookReserve
            let mayAct = !onlyFinalLookLeft && actions < maxActions && actingTime > .zero
            let passTime = mayAct ? actingTime : remaining
            let isStalled = stalledPasses >= maxStalledPasses
            let labels = labels
            let skip = skipping
            let fewest = fewestSeen
            let pass = await surface.pass(timeLimit: passTime) { elements in
                // The stall count lags one pass behind, so a read that itself
                // shows progress may still act.
                guard mayAct, !isStalled || elements.count < fewest else { return nil }
                return SystemNotificationDismissPolicy.nextTarget(in: elements, labels: labels, skipping: skip)
            }
            let count = pass.present.count
            let seenBefore = mostSeen
            mostSeen = max(mostSeen, count)

            if let target = pass.actedOn {
                actions += 1
                attempts[target, default: 0] += 1
                if attempts[target, default: 0] >= maxAttemptsPerElement {
                    skipping.insert(target)
                }
                if count < fewestSeen {
                    fewestSeen = count
                    stalledPasses = 0
                } else {
                    stalledPasses += 1
                }
                await pause(before: deadline)
                continue
            }
            if pass.isComplete {
                if count == 0 { return actions > 0 ? .dismissed : .nothingToDismiss }
                // An earlier pass saw more notifications than remain.
                return count < seenBefore ? .partial : .failed
            }
            incompleteRereads += 1
            if incompleteRereads > maxIncompleteRereads {
                guard mayAct, passTime < finalLookReserve else { return .failed }
                onlyFinalLookLeft = true
            }
            await pause(before: deadline)
        }
    }

    /// Waits `settleInterval`, but never past `deadline`.
    private func pause(before deadline: C.Instant) async {
        let wait = min(settleInterval, clock.now.duration(to: deadline))
        guard wait > .zero else { return }
        try? await clock.sleep(for: wait)
    }
}

extension SystemNotificationDismisser where C == ContinuousClock {
    init(surface: any SystemNotificationSurface, labels: SystemNotificationDismissLabels) {
        self.init(surface: surface, labels: labels, clock: ContinuousClock())
    }
}
