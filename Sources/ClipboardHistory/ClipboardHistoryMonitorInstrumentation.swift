import Foundation
import os.lock

public struct ClipboardHistoryMonitorMetrics: Equatable, Sendable {
    public let keyHintCount: Int
    public let idleTimerFireCount: Int
    public let boostedTimerFireCount: Int
    public let observedChangeCount: Int
    public let capturedChangeCount: Int
    public let overwrittenGenerationCount: Int

    public init(
        keyHintCount: Int,
        idleTimerFireCount: Int,
        boostedTimerFireCount: Int,
        observedChangeCount: Int,
        capturedChangeCount: Int,
        overwrittenGenerationCount: Int
    ) {
        self.keyHintCount = keyHintCount
        self.idleTimerFireCount = idleTimerFireCount
        self.boostedTimerFireCount = boostedTimerFireCount
        self.observedChangeCount = observedChangeCount
        self.capturedChangeCount = capturedChangeCount
        self.overwrittenGenerationCount = overwrittenGenerationCount
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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

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

    func snapshot() -> ClipboardHistoryMonitorMetrics {
        state.withLock { state in
            ClipboardHistoryMonitorMetrics(
                keyHintCount: state.keyHintCount,
                idleTimerFireCount: state.idleTimerFireCount,
                boostedTimerFireCount: state.boostedTimerFireCount,
                observedChangeCount: state.observedChangeCount,
                capturedChangeCount: state.capturedChangeCount,
                overwrittenGenerationCount: state.overwrittenGenerationCount
            )
        }
    }
}
