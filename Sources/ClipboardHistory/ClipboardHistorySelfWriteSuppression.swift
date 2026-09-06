import Foundation
import os.lock

final class ClipboardHistorySelfWriteSuppression: Sendable {
    final class Token: Sendable {
        private let owner: ClipboardHistorySelfWriteSuppression
        private let finished = OSAllocatedUnfairLock(initialState: false)

        fileprivate init(owner: ClipboardHistorySelfWriteSuppression) {
            self.owner = owner
        }

        func finish(generation: Int) {
            let shouldFinish = finished.withLock { finished in
                guard !finished else { return false }
                finished = true
                return true
            }
            guard shouldFinish else { return }
            owner.finish(generation: generation)
        }
    }

    private struct State: Sendable {
        var activeWriteCount = 0
        var completedGenerations: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func begin() -> Token {
        state.withLock { $0.activeWriteCount += 1 }
        return Token(owner: self)
    }

    func shouldSuppress(generation: Int) -> Bool {
        state.withLock { state in
            if state.activeWriteCount > 0 {
                return true
            }
            return state.completedGenerations.contains(generation)
        }
    }

    private func finish(generation: Int) {
        state.withLock { state in
            if state.activeWriteCount > 0 {
                state.activeWriteCount -= 1
            }
            state.completedGenerations.insert(generation)
            if state.completedGenerations.count > 32 {
                state.completedGenerations.remove(
                    state.completedGenerations.min() ?? generation
                )
            }
        }
    }
}
