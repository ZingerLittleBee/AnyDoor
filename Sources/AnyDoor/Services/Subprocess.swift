import Foundation
import os

// MARK: - Subprocess runner protocol

/// Runs one child process to completion. Callers depend on this protocol so
/// tests can substitute a stub instead of spawning the real binary.
protocol SubprocessRunning: Sendable {
    /// Launches `executableURL` and waits until it exits and both of its output
    /// streams are drained.
    ///
    /// - Parameter timeout: The child's time budget. Once it runs out, the child
    ///   is terminated and the result reports `timedOut`. Pass `nil` for an
    ///   interactive child that has no meaningful budget (`screencapture -i`).
    /// - Throws: `SubprocessError.spawnFailed` when the executable cannot be
    ///   launched, and `CancellationError` when the calling task is cancelled
    ///   (the child is terminated first). A non-zero exit and a timeout are
    ///   reported in the result, never thrown.
    func run(_ executableURL: URL, arguments: [String], timeout: Duration?) async throws -> SubprocessResult
}

struct SubprocessResult: Sendable, Equatable {
    let stdout: String
    let stderr: String
    /// The termination status; the signal number when a signal ended the child
    /// (15 after the watchdog's SIGTERM).
    let exit: Int32
    /// The watchdog terminated the child because it was still running when its
    /// timeout ran out.
    let timedOut: Bool
}

enum SubprocessError: Error, Equatable {
    case spawnFailed(String)
}

// MARK: - ProcessRunner

/// The production `SubprocessRunning`. The child's stdin reads `/dev/null`, and
/// its stdout and stderr are captured separately.
///
/// The exit is observed through a `terminationHandler` installed before
/// `run()`, never `waitUntilExit()`: called after the pipes reached EOF, that
/// can block forever even though the child has already been reaped, which once
/// left the port list spinning. The watchdog stays armed until the child exits,
/// and it claims a timeout only for a child that has not exited, so a fast exit
/// can never be reported as timed out.
struct ProcessRunner: SubprocessRunning {
    func run(_ executableURL: URL, arguments: [String], timeout: Duration?) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let tracker = ExitTracker()
        process.terminationHandler = { _ in tracker.markExited() }

        try Task.checkCancellation()
        do { try process.run() }
        catch { throw SubprocessError.spawnFailed("\(error)") }

        return try await withTaskCancellationHandler {
            // Drain both pipes concurrently so a child that fills either pipe
            // buffer keeps running instead of blocking on write().
            async let outData: Data = readAll(outPipe.fileHandleForReading)
            async let errData: Data = readAll(errPipe.fileHandleForReading)

            let watchdog = timeout.map { budget in
                Task {
                    // Cancelled only once the child has exited: nothing to do.
                    do { try await Task.sleep(for: budget) } catch { return }
                    if tracker.claimTimeout() { process.terminate() }
                }
            }

            let out = await outData
            let err = await errData
            // A child can close its output long before it exits, so EOF alone
            // does not end the run and the watchdog keeps guarding it.
            await tracker.waitForExit()
            watchdog?.cancel()

            try Task.checkCancellation()
            return SubprocessResult(
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? "",
                exit: process.terminationStatus,
                timedOut: tracker.timedOut
            )
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Exit bookkeeping shared by the termination handler, the watchdog and the
/// waiting task. One lock orders the child's exit against the watchdog firing.
private final class ExitTracker: Sendable {
    private struct State {
        var exited = false
        var timedOut = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    var timedOut: Bool { lock.withLock { $0.timedOut } }

    /// Called by `terminationHandler`, which runs once per launched process.
    func markExited() {
        let waiter = lock.withLock { state -> CheckedContinuation<Void, Never>? in
            state.exited = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    /// Returns once `markExited()` has run. The continuation is resumed exactly
    /// once: right here when the exit came first, otherwise by `markExited()`.
    func waitForExit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let exited = lock.withLock { state -> Bool in
                if !state.exited { state.waiter = continuation }
                return state.exited
            }
            if exited { continuation.resume() }
        }
    }

    /// The watchdog's claim: true, and the run is marked timed out, only while
    /// the child has not exited yet.
    func claimTimeout() -> Bool {
        lock.withLock { state in
            guard !state.exited else { return false }
            state.timedOut = true
            return true
        }
    }
}

/// Reads `handle` to EOF on a GCD thread rather than blocking a cooperative
/// one. The closure owns the handle, so its descriptor stays open until the
/// read returns.
private func readAll(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { (cont: CheckedContinuation<Data, Never>) in
        DispatchQueue.global().async {
            let data = (try? handle.readToEnd()) ?? Data()
            cont.resume(returning: data)
        }
    }
}
