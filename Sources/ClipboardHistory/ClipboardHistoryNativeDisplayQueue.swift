import Foundation
import GRDB
import os

/// The timer belongs to one waiter, never the potentially blocked native worker.
/// Tests replace scheduling and admission observation, not filesystem results.
struct ClipboardHistoryNativeDisplayWaiting: Sendable {
    typealias Cancellation = @Sendable () -> Void
    let scheduleTimeout: @Sendable (@escaping @Sendable () -> Void) -> Cancellation
    let didAdmit: @Sendable () -> Void

    static let live = ClipboardHistoryNativeDisplayWaiting(scheduleTimeout: { expired in
        let timeoutTask = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(2))
                expired()
            } catch {}
        }
        return { timeoutTask.cancel() }
    }, didAdmit: {})
}

/// Synchronous filesystem calls have no cooperative cancellation deadline.
/// One serial worker confines them to Dispatch; cancelled queued requests are
/// removed and identical snapshots share work without sharing cancellation.
final class ClipboardHistoryNativeDisplayQueue: Sendable {
    static let shared = ClipboardHistoryNativeDisplayQueue()
    enum WaitError: Error { case timedOut }

    struct Key: Equatable, Sendable {
        enum Request: Equatable, Sendable {
            case page(ClipboardHistoryQuery, ClipboardHistoryCursor?)
            case mutation(ClipboardHistoryEntryID)
        }
        // Retaining identity prevents address reuse; this is never permission
        // to access the pool. Callers must recheck their live pool after await.
        let pool: DatabasePool
        let epoch: Int
        let revision: Int64
        let request: Request
        // Retention can change the SQL result without changing its revision.
        let page: ClipboardHistoryPage

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pool === rhs.pool && lhs.epoch == rhs.epoch && lhs.revision == rhs.revision
                && lhs.request == rhs.request && lhs.page == rhs.page
        }
    }

    typealias Work = @Sendable (@escaping @Sendable () throws -> Void) throws -> ClipboardHistoryResolvedDisplay
    private typealias Continuation = CheckedContinuation<ClipboardHistoryResolvedDisplay, any Error>

    private final class Waiter: Sendable {
        let id = UUID()
        private struct State {
            var continuation: Continuation?
            var cancelled = false
            var completed = false
            var cancelTimeout: ClipboardHistoryNativeDisplayWaiting.Cancellation?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        var isCancelled: Bool { state.withLock { $0.cancelled } }

        func install(_ continuation: Continuation) -> Bool {
            state.withLock {
                guard !$0.cancelled, !$0.completed else { return false }
                $0.continuation = continuation
                return true
            }
        }

        func installTimeoutCancellation(_ cancel: @escaping ClipboardHistoryNativeDisplayWaiting.Cancellation) {
            let completed = state.withLock { value in
                guard !value.completed, !value.cancelled else { return true }
                value.cancelTimeout = cancel
                return false
            }
            if completed { cancel() }
        }

        func cancel(with error: any Error = CancellationError()) {
            let pending = state.withLock { value -> (Continuation?, ClipboardHistoryNativeDisplayWaiting.Cancellation?) in
                value.cancelled = true
                guard !value.completed else { return (nil, nil) }
                value.completed = true
                let pending = (value.continuation, value.cancelTimeout)
                value.continuation = nil
                value.cancelTimeout = nil
                return pending
            }
            pending.1?()
            pending.0?.resume(throwing: error)
        }

        func finish(_ result: Result<ClipboardHistoryResolvedDisplay, any Error>) {
            let pending = state.withLock { value -> (Continuation?, ClipboardHistoryNativeDisplayWaiting.Cancellation?) in
                guard !value.completed else { return (nil, nil) }
                value.completed = true
                let pending = (value.continuation, value.cancelTimeout)
                value.continuation = nil
                value.cancelTimeout = nil
                return pending
            }
            pending.1?()
            pending.0?.resume(with: result)
        }
    }

    private struct Job: Sendable {
        let id = UUID()
        let key: Key
        let work: Work
        var waiters: [Waiter]
        var cancelled = false
    }
    private struct State {
        var active: Job?
        var queued: [Job] = []
        var draining = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "dev.bybee.AnyDoor.clipboard-native-display", qos: .userInitiated)

    func resolve(key: Key, waiting: ClipboardHistoryNativeDisplayWaiting = .live,
        work: @escaping Work) async throws -> ClipboardHistoryResolvedDisplay {
        let waiter = Waiter()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await withCheckedThrowingContinuation { continuation in
                guard waiter.install(continuation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let admission = state.withLock { value -> (admitted: Bool, startsWorker: Bool) in
                    guard !waiter.isCancelled else { return (false, false) }
                    if value.active?.key == key, value.active?.cancelled == false {
                        value.active?.waiters.append(waiter)
                    } else if let index = value.queued.firstIndex(where: { $0.key == key }) {
                        value.queued[index].waiters.append(waiter)
                    } else {
                        value.queued.append(Job(key: key, work: work, waiters: [waiter]))
                    }
                    guard !value.draining else { return (true, false) }
                    value.draining = true
                    return (true, true)
                }
                if admission.admitted {
                    let cancelTimeout = waiting.scheduleTimeout {
                        waiter.cancel(with: WaitError.timedOut)
                        self.remove(waiter)
                    }
                    waiter.installTimeoutCancellation(cancelTimeout)
                    waiting.didAdmit()
                }
                if admission.startsWorker { queue.async { self.drain() } }
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            waiter.cancel()
            self.remove(waiter)
        }
    }

    private func remove(_ waiter: Waiter) {
        state.withLock { value in
            if value.active != nil {
                value.active?.waiters.removeAll { $0.id == waiter.id }
                if value.active?.waiters.isEmpty == true { value.active?.cancelled = true }
            }
            for index in value.queued.indices { value.queued[index].waiters.removeAll { $0.id == waiter.id } }
            value.queued.removeAll { $0.waiters.isEmpty }
        }
    }

    private func drain() {
        while let job = state.withLock({ value -> Job? in
            guard !value.queued.isEmpty else { value.draining = false; return nil }
            let job = value.queued.removeFirst()
            value.active = job
            return job
        }) {
            let result = Result {
                try job.work {
                    let cancelled = self.state.withLock { $0.active?.id != job.id || $0.active?.cancelled == true }
                    if cancelled { throw CancellationError() }
                }
            }
            let waiters = state.withLock { value -> [Waiter] in
                let waiters = value.active?.waiters ?? []
                value.active = nil
                return waiters
            }
            for waiter in waiters { waiter.finish(result) }
        }
    }
}
