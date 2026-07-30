import Foundation

struct ClipboardHistoryMonitorScheduler {
    enum Event: Equatable, Sendable {
        case setEnabled(Bool)
        case keyHint
        case timerFired
        case observationCompleted(changed: Bool)
        case willSleep
        case didWake
        case screenLocked
        case screenUnlocked
        case migrationStarted
        case migrationCompleted
    }

    struct ScheduledFire: Equatable, Sendable {
        let deadline: Duration
        let tolerance: Duration
    }

    struct Plan: Equatable, Sendable {
        let establishBaseline: Bool
        let observeNow: Bool
        let nextFire: ScheduledFire?
    }

    private static let idleInterval = Duration.milliseconds(500)
    private static let idleTolerance = Duration.milliseconds(50)
    private static let keyInterval = Duration.milliseconds(50)
    private static let keyTolerance = Duration.milliseconds(5)
    private static let keyWindow = Duration.milliseconds(500)
    private static let postChangeInterval = Duration.milliseconds(100)
    private static let postChangeTolerance = Duration.milliseconds(10)
    private static let postChangeWindow = Duration.milliseconds(500)

    private var isEnabled = false
    private var isSleeping = false
    private var isScreenLocked = false
    private var isMigrating = false
    private var wasActive = false
    private var keyWindowEndsAt: Duration?
    private var postChangeWindowEndsAt: Duration?

    mutating func handle(_ event: Event, at now: Duration) -> Plan {
        let wasActiveBeforeEvent = isActive
        var observeNow = false

        switch event {
        case .setEnabled(let enabled):
            isEnabled = enabled
        case .keyHint:
            if isActive {
                keyWindowEndsAt = now + Self.keyWindow
                postChangeWindowEndsAt = nil
                observeNow = true
            }
        case .timerFired:
            observeNow = isActive
        case .observationCompleted(let changed):
            if changed, isActive, !isInsideKeyWindow(at: now) {
                postChangeWindowEndsAt = now + Self.postChangeWindow
            }
        case .willSleep:
            isSleeping = true
        case .didWake:
            isSleeping = false
        case .screenLocked:
            isScreenLocked = true
        case .screenUnlocked:
            isScreenLocked = false
        case .migrationStarted:
            isMigrating = true
        case .migrationCompleted:
            isMigrating = false
        }

        let active = isActive
        let establishBaseline = active && !wasActiveBeforeEvent
        wasActive = active

        guard active else {
            keyWindowEndsAt = nil
            postChangeWindowEndsAt = nil
            return Plan(
                establishBaseline: false,
                observeNow: false,
                nextFire: nil
            )
        }

        let nextFire: ScheduledFire
        if isInsideKeyWindow(at: now) {
            nextFire = ScheduledFire(
                deadline: now + Self.keyInterval,
                tolerance: Self.keyTolerance
            )
        } else if isInsidePostChangeWindow(at: now) {
            nextFire = ScheduledFire(
                deadline: now + Self.postChangeInterval,
                tolerance: Self.postChangeTolerance
            )
        } else {
            keyWindowEndsAt = nil
            postChangeWindowEndsAt = nil
            nextFire = ScheduledFire(
                deadline: now + Self.idleInterval,
                tolerance: Self.idleTolerance
            )
        }

        return Plan(
            establishBaseline: establishBaseline,
            observeNow: observeNow,
            nextFire: nextFire
        )
    }

    private var isActive: Bool {
        isEnabled && !isSleeping && !isScreenLocked && !isMigrating
    }

    private func isInsideKeyWindow(at now: Duration) -> Bool {
        keyWindowEndsAt.map { now < $0 } ?? false
    }

    private func isInsidePostChangeWindow(at now: Duration) -> Bool {
        postChangeWindowEndsAt.map { now < $0 } ?? false
    }
}
