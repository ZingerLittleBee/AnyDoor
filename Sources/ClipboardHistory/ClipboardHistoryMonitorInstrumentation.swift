import Foundation
import os.lock

public struct ClipboardHistoryMonitorMetrics: Equatable, Sendable {
    public let keyHintCount: Int
    public let idleTimerFireCount: Int
    public let boostedTimerFireCount: Int
    public let observedChangeCount: Int
    public let capturedChangeCount: Int
    public let overwrittenGenerationCount: Int
    /// How long the monitor's timer has run, summed over every start and
    /// stop. Time while monitoring is off, the Mac sleeps, the screen is
    /// locked, or a migration runs is left out. Idle and boosted polling both
    /// count, so `idleTimerFireCount` divided by it is the idle fire rate only
    /// in an idle trial.
    public let monitoringDuration: Duration

    public init(
        keyHintCount: Int,
        idleTimerFireCount: Int,
        boostedTimerFireCount: Int,
        observedChangeCount: Int,
        capturedChangeCount: Int,
        overwrittenGenerationCount: Int,
        monitoringDuration: Duration
    ) {
        self.keyHintCount = keyHintCount
        self.idleTimerFireCount = idleTimerFireCount
        self.boostedTimerFireCount = boostedTimerFireCount
        self.observedChangeCount = observedChangeCount
        self.capturedChangeCount = capturedChangeCount
        self.overwrittenGenerationCount = overwrittenGenerationCount
        self.monitoringDuration = monitoringDuration
    }
}

final class ClipboardHistoryMonitorInstrumentation: Sendable {
    private struct State: Sendable {
        var keyHintCount = 0
        var idleTimerFireCount = 0
        var boostedTimerFireCount = 0
        var observedChangeCount = 0
        var capturedChangeCount = 0
        var overwrittenGenerationCount = 0
        var completedMonitoringDuration = Duration.zero
        var monitoringStartedAt: Duration?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let uptime: @Sendable () -> Duration

    /// `uptime` reads the system uptime, which stops while the Mac sleeps.
    init(
        uptime: @escaping @Sendable () -> Duration = {
            .seconds(ProcessInfo.processInfo.systemUptime)
        }
    ) {
        self.uptime = uptime
    }

    func recordKeyHint() {
        state.withLock { $0.keyHintCount += 1 }
    }

    func recordTimerFire(isIdle: Bool) {
        state.withLock { state in
            if isIdle {
                state.idleTimerFireCount += 1
            } else {
                state.boostedTimerFireCount += 1
            }
        }
    }

    func recordObservedGeneration(previous: Int?, current: Int) {
        state.withLock { state in
            state.observedChangeCount += 1
            if let previous, current > previous + 1 {
                state.overwrittenGenerationCount += current - previous - 1
            }
        }
    }

    func recordCapture() {
        state.withLock { $0.capturedChangeCount += 1 }
    }

    /// Called whenever the monitor's timer starts or stops running.
    func recordMonitoringActive(_ isActive: Bool) {
        state.withLock { state in
            let now = uptime()
            if isActive {
                if state.monitoringStartedAt == nil {
                    state.monitoringStartedAt = now
                }
            } else if let startedAt = state.monitoringStartedAt {
                state.completedMonitoringDuration += now - startedAt
                state.monitoringStartedAt = nil
            }
        }
    }

    func snapshot() -> ClipboardHistoryMonitorMetrics {
        state.withLock { state in
            let runningDuration = state.monitoringStartedAt.map {
                uptime() - $0
            } ?? .zero
            return ClipboardHistoryMonitorMetrics(
                keyHintCount: state.keyHintCount,
                idleTimerFireCount: state.idleTimerFireCount,
                boostedTimerFireCount: state.boostedTimerFireCount,
                observedChangeCount: state.observedChangeCount,
                capturedChangeCount: state.capturedChangeCount,
                overwrittenGenerationCount: state.overwrittenGenerationCount,
                monitoringDuration: state.completedMonitoringDuration
                    + runningDuration
            )
        }
    }
}
